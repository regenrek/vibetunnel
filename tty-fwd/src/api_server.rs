use anyhow::Result;
use data_encoding::BASE64;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::SystemTime;
use uuid::Uuid;

use crate::http_server::{HttpRequest, HttpServer, Method, Response, StatusCode};
use crate::sessions;

// Types matching the TypeScript interface
#[derive(Debug, Serialize, Deserialize)]
struct SessionInfo {
    cmdline: Vec<String>,
    cwd: String,
    exit_code: Option<i32>,
    name: String,
    pid: Option<u32>,
    started_at: String,
    status: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct SessionListEntry {
    session_info: SessionInfo,
    #[serde(rename = "stream-out")]
    stream_out: String,
    stdin: String,
    notification_stream: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct SessionResponse {
    id: String,
    command: String,
    #[serde(rename = "workingDir")]
    working_dir: String,
    status: String,
    #[serde(rename = "exitCode")]
    exit_code: Option<i32>,
    #[serde(rename = "startedAt")]
    started_at: String,
    #[serde(rename = "lastModified")]
    last_modified: String,
    pid: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct CreateSessionRequest {
    command: Vec<String>,
    #[serde(rename = "workingDir")]
    working_dir: Option<String>,
    #[serde(default = "default_term_value")]
    term: String,
}

fn default_term_value() -> String {
    "xterm".to_string()
}

#[derive(Debug, Deserialize)]
struct InputRequest {
    text: String,
}

#[derive(Debug, Deserialize)]
struct MkdirRequest {
    path: String,
}

#[derive(Debug, Serialize)]
struct ApiResponse {
    success: Option<bool>,
    message: Option<String>,
    error: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
}

fn check_basic_auth(req: &HttpRequest, expected_password: &str) -> bool {
    if let Some(auth_header) = req.headers().get("authorization") {
        if let Ok(auth_str) = auth_header.to_str() {
            if let Some(credentials) = auth_str.strip_prefix("Basic ") {
                if let Ok(decoded_bytes) = BASE64.decode(credentials.as_bytes()) {
                    if let Ok(decoded_str) = String::from_utf8(decoded_bytes) {
                        if let Some(colon_pos) = decoded_str.find(':') {
                            let password = &decoded_str[colon_pos + 1..];
                            return password == expected_password;
                        }
                    }
                }
            }
        }
    }
    false
}

fn unauthorized_response() -> Response<String> {
    Response::builder()
        .status(StatusCode::UNAUTHORIZED)
        .header("WWW-Authenticate", "Basic realm=\"tty-fwd\"")
        .header("Content-Type", "text/plain")
        .body("Unauthorized".to_string())
        .unwrap()
}

fn get_mime_type(file_path: &Path) -> &'static str {
    match file_path.extension().and_then(|ext| ext.to_str()) {
        Some("html") | Some("htm") => "text/html",
        Some("css") => "text/css",
        Some("js") | Some("mjs") => "application/javascript",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("txt") => "text/plain",
        Some("xml") => "application/xml",
        Some("woff") => "font/woff",
        Some("woff2") => "font/woff2",
        Some("ttf") => "font/ttf",
        Some("otf") => "font/otf",
        Some("mp4") => "video/mp4",
        Some("webm") => "video/webm",
        Some("mp3") => "audio/mpeg",
        Some("wav") => "audio/wav",
        Some("ogg") => "audio/ogg",
        _ => "application/octet-stream",
    }
}

fn serve_static_file(static_root: &Path, request_path: &str) -> Option<Response<Vec<u8>>> {
    // Security check: prevent directory traversal attacks
    if request_path.contains("../") || request_path.contains("..\\") {
        return None;
    }

    let cleaned_path = request_path.trim_start_matches('/');
    let file_path = static_root.join(cleaned_path);

    println!(
        "Static file request: '{}' -> cleaned: '{}' -> file_path: '{}'",
        request_path,
        cleaned_path,
        file_path.display()
    );

    // Security check: ensure the file path is within the static root
    if !file_path.starts_with(static_root) {
        println!("Security check failed: file_path does not start with static_root");
        return None;
    }

    if file_path.is_file() {
        // Serve the file directly
        match fs::read(&file_path) {
            Ok(content) => {
                let mime_type = get_mime_type(&file_path);

                Some(
                    Response::builder()
                        .status(StatusCode::OK)
                        .header("Content-Type", mime_type)
                        .header("Access-Control-Allow-Origin", "*")
                        .body(content)
                        .unwrap(),
                )
            }
            Err(_) => {
                let error_msg = "Failed to read file".as_bytes().to_vec();
                Some(
                    Response::builder()
                        .status(StatusCode::INTERNAL_SERVER_ERROR)
                        .header("Content-Type", "text/plain")
                        .body(error_msg)
                        .unwrap(),
                )
            }
        }
    } else if file_path.is_dir() {
        // Try to serve index.html from the directory
        let index_path = file_path.join("index.html");
        println!("Checking for index.html at: {}", index_path.display());
        if index_path.is_file() {
            println!("Found index.html, serving it");
            match fs::read(&index_path) {
                Ok(content) => Some(
                    Response::builder()
                        .status(StatusCode::OK)
                        .header("Content-Type", "text/html")
                        .header("Access-Control-Allow-Origin", "*")
                        .body(content)
                        .unwrap(),
                ),
                Err(_) => {
                    let error_msg = "Failed to read index.html".as_bytes().to_vec();
                    Some(
                        Response::builder()
                            .status(StatusCode::INTERNAL_SERVER_ERROR)
                            .header("Content-Type", "text/plain")
                            .body(error_msg)
                            .unwrap(),
                    )
                }
            }
        } else {
            println!("index.html not found at: {}", index_path.display());
            None // Directory doesn't have index.html
        }
    } else {
        println!(
            "Path is neither file nor directory: {}",
            file_path.display()
        );
        None // File doesn't exist
    }
}

pub fn start_server(
    bind_address: &str,
    control_path: PathBuf,
    static_path: Option<String>,
    password: Option<String>,
) -> Result<()> {
    fs::create_dir_all(&control_path)?;

    let server = HttpServer::bind(bind_address)
        .map_err(|e| anyhow::anyhow!("Failed to bind server: {}", e))?;

    // Set up auth if password is provided
    let auth_password = if let Some(ref password) = password {
        println!(
            "HTTP API server listening on {} with Basic Auth enabled (any username)",
            bind_address
        );
        Some(password.clone())
    } else {
        println!(
            "HTTP API server listening on {} with no authentication",
            bind_address
        );
        None
    };

    for req in server.incoming() {
        let control_path = control_path.clone();
        let static_path = static_path.clone();
        let auth_password = auth_password.clone();

        thread::spawn(move || {
            let mut req = match req {
                Ok(req) => req,
                Err(e) => {
                    eprintln!("Request error: {}", e);
                    return;
                }
            };

            let method = req.method();
            let path = req.uri().path().to_string();
            let full_uri = req.uri().to_string();

            println!("{:?} {} (full URI: {})", method, path, full_uri);

            // Check authentication if enabled (but skip /api/health)
            if let Some(ref expected_password) = auth_password {
                if path != "/api/health" && !check_basic_auth(&req, expected_password) {
                    let _ = req.respond(unauthorized_response());
                    return;
                }
            }

            // Check for static file serving first
            if method == &Method::GET && !path.starts_with("/api/") {
                if let Some(ref static_dir) = static_path {
                    let static_dir_path = Path::new(static_dir);
                    println!(
                        "Static dir check: '{}' -> exists: {}, is_dir: {}",
                        static_dir,
                        static_dir_path.exists(),
                        static_dir_path.is_dir()
                    );
                    if static_dir_path.exists() && static_dir_path.is_dir() {
                        if let Some(static_response) = serve_static_file(static_dir_path, &path) {
                            let _ = req.respond(static_response);
                            return;
                        }
                    }
                } else {
                    println!("No static_path configured");
                }
            }

            let response = match (method, path.as_str()) {
                (&Method::GET, "/api/health") => handle_health(),
                (&Method::GET, "/api/sessions") => handle_list_sessions(&control_path),
                (&Method::POST, "/api/sessions") => handle_create_session(&control_path, &mut req),
                (&Method::POST, "/api/cleanup-exited") => handle_cleanup_exited(&control_path),
                (&Method::POST, "/api/mkdir") => handle_mkdir(&mut req),
                (&Method::GET, "/api/stream-all") => {
                    // Handle streaming all sessions - bypass normal response handling
                    return handle_stream_all_sessions(&control_path, &mut req);
                }
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/stream") =>
                {
                    // Handle streaming differently - bypass normal response handling
                    return handle_session_stream_direct(&control_path, &path, &mut req);
                }
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/snapshot") =>
                {
                    handle_session_snapshot(&control_path, &path)
                }
                (&Method::POST, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/input") =>
                {
                    handle_session_input(&control_path, &path, &mut req)
                }
                (&Method::DELETE, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/cleanup") =>
                {
                    handle_session_cleanup(&control_path, &path)
                }
                (&Method::DELETE, path) if path.starts_with("/api/sessions/") => {
                    handle_session_kill(&control_path, &path)
                }
                _ => {
                    let error = ApiResponse {
                        success: None,
                        message: None,
                        error: Some("Not found".to_string()),
                        session_id: None,
                    };
                    json_response(StatusCode::NOT_FOUND, &error)
                }
            };

            let _ = req.respond(response);
        });
    }

    Ok(())
}

fn extract_session_id(path: &str) -> Option<String> {
    let re = Regex::new(r"/api/sessions/([^/]+)($|/)").unwrap();
    re.captures(path)
        .and_then(|caps| caps.get(1))
        .map(|m| m.as_str().to_string())
}

fn json_response<T: Serialize>(status: StatusCode, data: &T) -> Response<String> {
    let json = serde_json::to_string(data).unwrap_or_else(|_| "{}".to_string());
    Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .header("Access-Control-Allow-Origin", "*")
        .body(json)
        .unwrap()
}

fn handle_health() -> Response<String> {
    let response = ApiResponse {
        success: Some(true),
        message: Some("OK".to_string()),
        error: None,
        session_id: None,
    };
    json_response(StatusCode::OK, &response)
}

fn handle_list_sessions(control_path: &PathBuf) -> Response<String> {
    match sessions::list_sessions(control_path) {
        Ok(sessions) => {
            let mut session_responses = Vec::new();

            for (session_id, entry) in sessions {
                let started_at_str = entry
                    .session_info
                    .started_at
                    .map(|ts| ts.to_string())
                    .unwrap_or_else(|| "unknown".to_string());

                let last_modified =
                    get_last_modified(&entry.stream_out).unwrap_or_else(|| started_at_str.clone());

                session_responses.push(SessionResponse {
                    id: session_id,
                    command: entry.session_info.cmdline.join(" "),
                    working_dir: entry.session_info.cwd,
                    status: entry.session_info.status,
                    exit_code: entry.session_info.exit_code,
                    started_at: started_at_str,
                    last_modified,
                    pid: entry.session_info.pid,
                });
            }

            session_responses.sort_by(|a, b| b.last_modified.cmp(&a.last_modified));
            json_response(StatusCode::OK, &session_responses)
        }
        Err(e) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to list sessions: {}", e)),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}

fn handle_create_session(
    control_path: &PathBuf,
    req: &mut crate::http_server::HttpRequest,
) -> Response<String> {
    // Read the request body
    let body_bytes = req.body();
    let body = String::from_utf8_lossy(body_bytes);

    let create_request = match serde_json::from_str::<CreateSessionRequest>(&body) {
        Ok(request) => request,
        Err(_) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Invalid request body. Expected JSON with 'command' array and optional 'workingDir'".to_string()),
                session_id: None,
            };
            return json_response(StatusCode::BAD_REQUEST, &error);
        }
    };

    if create_request.command.is_empty() {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Command cannot be empty".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
    }

    // Generate a new session ID
    let session_id = Uuid::new_v4().to_string();
    let session_path = control_path.join(&session_id);

    // Create session directory
    if let Err(e) = fs::create_dir_all(&session_path) {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some(format!("Failed to create session directory: {}", e)),
            session_id: None,
        };
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
    }

    // Paths are set up within the spawned thread

    // Convert command to OsString vector
    let cmdline: Vec<std::ffi::OsString> = create_request
        .command
        .iter()
        .map(|s| std::ffi::OsString::from(s))
        .collect();

    // Set working directory if specified, with tilde expansion
    let current_dir = if let Some(ref working_dir) = create_request.working_dir {
        // Expand ~ to home directory if needed
        let expanded_dir = if working_dir.starts_with('~') {
            if let Some(home_dir) = std::env::var_os("HOME") {
                let home_path = std::path::Path::new(&home_dir);
                let remaining_path = &working_dir[1..]; // Remove the ~ character
                if remaining_path.is_empty() {
                    home_path.to_path_buf()
                } else {
                    home_path.join(remaining_path.trim_start_matches('/'))
                }
            } else {
                // Fall back to the original path if HOME is not set
                std::path::PathBuf::from(working_dir)
            }
        } else {
            std::path::PathBuf::from(working_dir)
        };

        // Validate the expanded directory exists
        if !expanded_dir.exists() {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some(format!(
                    "Working directory does not exist: {}",
                    expanded_dir.display()
                )),
                session_id: None,
            };
            return json_response(StatusCode::BAD_REQUEST, &error);
        }
        expanded_dir.to_string_lossy().to_string()
    } else {
        std::env::current_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| "/".to_string())
    };

    // Spawn the process in a detached manner using a separate thread
    let control_path_clone = control_path.clone();
    let session_id_clone = session_id.clone();
    let cmdline_clone = cmdline.clone();
    let working_dir_clone = current_dir.clone();
    let term_clone = create_request.term.clone();

    std::thread::Builder::new()
        .name(format!("session-{}", session_id_clone))
        .spawn(move || {
            // Change to the specified working directory before spawning
            let original_dir = std::env::current_dir().ok();
            if let Err(e) = std::env::set_current_dir(&working_dir_clone) {
                eprintln!(
                    "Failed to change to working directory {}: {}",
                    working_dir_clone, e
                );
                return;
            }

            // Set up TtySpawn
            let mut tty_spawn = crate::tty_spawn::TtySpawn::new_cmdline(
                cmdline_clone.iter().map(|s| s.as_os_str()),
            );
            let session_path = control_path_clone.join(&session_id_clone);
            let session_info_path = session_path.join("session.json");
            let stream_out_path = session_path.join("stream-out");
            let stdin_path = session_path.join("stdin");
            let notification_stream_path = session_path.join("notification-stream");

            if let Err(e) = tty_spawn
                .stdout_path(&stream_out_path, true)
                .and_then(|spawn| spawn.stdin_path(&stdin_path))
            {
                eprintln!(
                    "Failed to set up TTY paths for session {}: {}",
                    session_id_clone, e
                );
                return;
            }

            tty_spawn.session_json_path(&session_info_path);

            if let Err(e) = tty_spawn.notification_path(&notification_stream_path) {
                eprintln!(
                    "Failed to set up notification path for session {}: {}",
                    session_id_clone, e
                );
                return;
            }

            // Set session name based on the first command
            let session_name = cmdline_clone
                .first()
                .and_then(|cmd| cmd.to_str())
                .map(|s| s.split('/').last().unwrap_or(s))
                .unwrap_or("unknown")
                .to_string();
            tty_spawn.session_name(session_name);

            // Set the TERM environment variable
            tty_spawn.term(term_clone);

            // Enable detached mode for API-created sessions
            tty_spawn.detached(true);

            // Spawn the process (this will block until the process exits)
            match tty_spawn.spawn() {
                Ok(exit_code) => {
                    println!(
                        "Session {} exited with code {}",
                        session_id_clone, exit_code
                    );
                }
                Err(e) => {
                    eprintln!("Failed to spawn session {}: {}", session_id_clone, e);
                }
            }

            // Restore original directory
            if let Some(original) = original_dir {
                let _ = std::env::set_current_dir(original);
            }
        })
        .expect("Failed to spawn session thread");

    // Return success response immediately
    let response = ApiResponse {
        success: Some(true),
        message: Some("Session created successfully".to_string()),
        error: None,
        session_id: Some(session_id),
    };
    json_response(StatusCode::OK, &response)
}

fn handle_cleanup_exited(control_path: &PathBuf) -> Response<String> {
    match sessions::cleanup_sessions(control_path, None) {
        Ok(_) => {
            let response = ApiResponse {
                success: Some(true),
                message: Some("All exited sessions cleaned up".to_string()),
                error: None,
                session_id: None,
            };
            json_response(StatusCode::OK, &response)
        }
        Err(e) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to cleanup sessions: {}", e)),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}

fn handle_session_snapshot(control_path: &PathBuf, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        let stream_path = control_path.join(&session_id).join("stream-out");

        match fs::read_to_string(&stream_path) {
            Ok(content) => Response::builder()
                .status(StatusCode::OK)
                .header("Content-Type", "text/plain")
                .body(content)
                .unwrap(),
            Err(_) => {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some("Session not found".to_string()),
                    session_id: None,
                };
                json_response(StatusCode::NOT_FOUND, &error)
            }
        }
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid session ID".to_string()),
            session_id: None,
        };
        json_response(StatusCode::BAD_REQUEST, &error)
    }
}

fn handle_session_input(
    control_path: &PathBuf,
    path: &str,
    req: &mut crate::http_server::HttpRequest,
) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        // Try to read the request body using the body() method
        let body_bytes = req.body();
        let body = String::from_utf8_lossy(body_bytes);
        if let Ok(input_req) = serde_json::from_str::<InputRequest>(&body) {
            // Check if text is empty
            if input_req.text.is_empty() {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some("Text is required".to_string()),
                    session_id: None,
                };
                return json_response(StatusCode::BAD_REQUEST, &error);
            }

            // First validate session exists and is running (like Node.js version)
            match sessions::list_sessions(control_path) {
                Ok(sessions) => {
                    if let Some(session_entry) = sessions.get(&session_id) {
                        // Check if session is running
                        if session_entry.session_info.status != "running" {
                            let error = ApiResponse {
                                success: None,
                                message: None,
                                error: Some("Session is not running".to_string()),
                                session_id: None,
                            };
                            return json_response(StatusCode::BAD_REQUEST, &error);
                        }

                        // Check if process is still alive
                        if let Some(pid) = session_entry.session_info.pid {
                            // Check if process exists (equivalent to Node.js process.kill(pid, 0))
                            let result = unsafe { libc::kill(pid as i32, 0) };
                            if result != 0 {
                                let error = ApiResponse {
                                    success: None,
                                    message: None,
                                    error: Some("Session process has died".to_string()),
                                    session_id: None,
                                };
                                return json_response(StatusCode::GONE, &error);
                            }
                        }

                        // Check if this is a special key (like Node.js version)
                        let special_keys = [
                            "arrow_up",
                            "arrow_down",
                            "arrow_left",
                            "arrow_right",
                            "escape",
                            "enter",
                            "ctrl_enter",
                            "shift_enter",
                        ];
                        let is_special_key = special_keys.contains(&input_req.text.as_str());

                        let result = if is_special_key {
                            sessions::send_key_to_session(
                                control_path,
                                &session_id,
                                &input_req.text,
                            )
                        } else {
                            sessions::send_text_to_session(
                                control_path,
                                &session_id,
                                &input_req.text,
                            )
                        };

                        match result {
                            Ok(_) => {
                                let response = ApiResponse {
                                    success: Some(true),
                                    message: Some("Input sent successfully".to_string()),
                                    error: None,
                                    session_id: None,
                                };
                                json_response(StatusCode::OK, &response)
                            }
                            Err(e) => {
                                let error = ApiResponse {
                                    success: None,
                                    message: None,
                                    error: Some(format!("Failed to send input: {}", e)),
                                    session_id: None,
                                };
                                json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
                            }
                        }
                    } else {
                        // Session not found
                        let error = ApiResponse {
                            success: None,
                            message: None,
                            error: Some("Session not found".to_string()),
                            session_id: None,
                        };
                        json_response(StatusCode::NOT_FOUND, &error)
                    }
                }
                Err(e) => {
                    let error = ApiResponse {
                        success: None,
                        message: None,
                        error: Some(format!("Failed to list sessions: {}", e)),
                        session_id: None,
                    };
                    json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
                }
            }
        } else {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Invalid request body".to_string()),
                session_id: None,
            };
            json_response(StatusCode::BAD_REQUEST, &error)
        }
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid session ID".to_string()),
            session_id: None,
        };
        json_response(StatusCode::BAD_REQUEST, &error)
    }
}

fn handle_session_kill(control_path: &PathBuf, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        // First check if session exists by listing sessions
        match sessions::list_sessions(control_path) {
            Ok(sessions) => {
                if let Some(session_entry) = sessions.get(&session_id) {
                    // Session exists, try to kill it
                    if let Some(_) = session_entry.session_info.pid {
                        // First try SIGTERM, then SIGKILL if needed (like Node.js version)
                        match sessions::send_signal_to_session(control_path, &session_id, 15) {
                            Ok(_) => {
                                // Successfully sent SIGTERM
                                let response = ApiResponse {
                                    success: Some(true),
                                    message: Some("Session killed".to_string()),
                                    error: None,
                                    session_id: None,
                                };
                                json_response(StatusCode::OK, &response)
                            }
                            Err(_) => {
                                // SIGTERM failed, try SIGKILL
                                match sessions::send_signal_to_session(control_path, &session_id, 9)
                                {
                                    Ok(_) => {
                                        let response = ApiResponse {
                                            success: Some(true),
                                            message: Some("Session killed".to_string()),
                                            error: None,
                                            session_id: None,
                                        };
                                        json_response(StatusCode::OK, &response)
                                    }
                                    Err(e) => {
                                        let error = ApiResponse {
                                            success: None,
                                            message: None,
                                            error: Some(format!("Failed to kill session: {}", e)),
                                            session_id: None,
                                        };
                                        json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
                                    }
                                }
                            }
                        }
                    } else {
                        // Session has no PID, consider it already dead
                        let response = ApiResponse {
                            success: Some(true),
                            message: Some("Session killed".to_string()),
                            error: None,
                            session_id: None,
                        };
                        json_response(StatusCode::OK, &response)
                    }
                } else {
                    // Session not found
                    let error = ApiResponse {
                        success: None,
                        message: None,
                        error: Some("Session not found".to_string()),
                        session_id: None,
                    };
                    json_response(StatusCode::NOT_FOUND, &error)
                }
            }
            Err(e) => {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some(format!("Failed to list sessions: {}", e)),
                    session_id: None,
                };
                json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
            }
        }
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid session ID".to_string()),
            session_id: None,
        };
        json_response(StatusCode::BAD_REQUEST, &error)
    }
}

fn handle_session_cleanup(control_path: &PathBuf, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        match sessions::cleanup_sessions(control_path, Some(&session_id)) {
            Ok(_) => {
                let response = ApiResponse {
                    success: Some(true),
                    message: Some("Session cleaned up".to_string()),
                    error: None,
                    session_id: None,
                };
                json_response(StatusCode::OK, &response)
            }
            Err(e) => {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some(format!("Failed to cleanup session: {}", e)),
                    session_id: None,
                };
                json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
            }
        }
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid session ID".to_string()),
            session_id: None,
        };
        json_response(StatusCode::BAD_REQUEST, &error)
    }
}

fn get_last_modified(file_path: &str) -> Option<String> {
    fs::metadata(file_path)
        .and_then(|metadata| metadata.modified())
        .map(|time| {
            time.duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                .to_string()
        })
        .ok()
}

fn handle_session_stream_direct(control_path: &PathBuf, path: &str, req: &mut HttpRequest) {
    let session_id = match extract_session_id(path) {
        Some(id) => id,
        None => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Invalid session ID".to_string()),
                session_id: None,
            };
            let response = json_response(StatusCode::BAD_REQUEST, &error);
            let _ = req.respond(response);
            return;
        }
    };

    // First check if the session exists
    let sessions = match sessions::list_sessions(control_path) {
        Ok(sessions) => sessions,
        Err(e) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to list sessions: {}", e)),
                session_id: None,
            };
            let response = json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
            let _ = req.respond(response);
            return;
        }
    };

    let session_entry = match sessions.get(&session_id) {
        Some(entry) => entry,
        None => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Session not found".to_string()),
                session_id: None,
            };
            let response = json_response(StatusCode::NOT_FOUND, &error);
            let _ = req.respond(response);
            return;
        }
    };

    let stream_out_path = &session_entry.stream_out;

    // Check if the stream-out file exists
    if !std::path::Path::new(stream_out_path).exists() {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Session stream file not found".to_string()),
            session_id: None,
        };
        let response = json_response(StatusCode::NOT_FOUND, &error);
        let _ = req.respond(response);
        return;
    }

    println!("Starting streaming SSE for session {}", session_id);

    // Send SSE headers
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "text/event-stream")
        .header("Cache-Control", "no-cache")
        .header("Connection", "keep-alive")
        .header("Access-Control-Allow-Origin", "*")
        .body(Vec::new())
        .unwrap();

    if let Err(e) = req.respond(response) {
        println!("Failed to send SSE headers: {}", e);
        return;
    }

    let start_time = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    // First, send existing content from the file
    if let Ok(content) = fs::read_to_string(stream_out_path) {
        let mut header_sent = false;

        for line in content.lines() {
            if line.trim().is_empty() {
                continue;
            }

            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) {
                // Check if this is a header line
                if parsed.get("version").is_some()
                    && parsed.get("width").is_some()
                    && parsed.get("height").is_some()
                {
                    let data = format!(
                        "data: {}

",
                        line
                    );
                    if let Err(e) = req.respond_raw(data.as_bytes()) {
                        println!("Failed to send header data: {}", e);
                        return;
                    }
                    header_sent = true;
                }
                // Check if this is an event line [timestamp, type, data]
                else if parsed.as_array().map(|arr| arr.len() >= 3).unwrap_or(false) {
                    // Convert to instant event for immediate playback
                    if let Some(arr) = parsed.as_array() {
                        let instant_event = serde_json::json!([0, arr[1], arr[2]]);
                        let data = format!(
                            "data: {}

",
                            instant_event
                        );
                        if let Err(e) = req.respond_raw(data.as_bytes()) {
                            println!("Failed to send event data: {}", e);
                            return;
                        }
                    }
                }
            }
        }

        // Send default header if none found
        if !header_sent {
            let default_header = serde_json::json!({
                "version": 2,
                "width": 80,
                "height": 24,
                "timestamp": start_time as u64,
                "env": { "TERM": session_entry.session_info.term.clone() }
            });
            let data = format!(
                "data: {}

",
                default_header
            );
            if let Err(e) = req.respond_raw(data.as_bytes()) {
                println!("Failed to send default header: {}", e);
                return;
            }
        }
    } else {
        // Send default header if file can't be read
        let default_header = serde_json::json!({
            "version": 2,
            "width": 80,
            "height": 24,
            "timestamp": start_time as u64,
            "env": { "TERM": session_entry.session_info.term.clone() }
        });
        let data = format!(
            "data: {}

",
            default_header
        );
        if let Err(e) = req.respond_raw(data.as_bytes()) {
            println!("Failed to send fallback header: {}", e);
            return;
        }
    }

    // Now use tail -f to stream new content with immediate flushing
    let stream_path_clone = stream_out_path.clone();

    match Command::new("tail")
        .args(&["-f", &stream_path_clone])
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(mut child) => {
            if let Some(stdout) = child.stdout.take() {
                let reader = BufReader::new(stdout);

                // Stream lines immediately as they come in
                for line in reader.lines() {
                    match line {
                        Ok(line) => {
                            if line.trim().is_empty() {
                                continue;
                            }

                            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&line) {
                                // Skip headers in tail output
                                if parsed.get("version").is_some() && parsed.get("width").is_some()
                                {
                                    continue;
                                }

                                // Process event lines
                                if let Some(arr) = parsed.as_array() {
                                    if arr.len() >= 3 {
                                        let current_time = SystemTime::now()
                                            .duration_since(SystemTime::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_secs_f64();
                                        let real_time_event = serde_json::json!([
                                            current_time - start_time,
                                            arr[1],
                                            arr[2]
                                        ]);
                                        let data = format!(
                                            "data: {}

",
                                            real_time_event
                                        );
                                        if let Err(e) = req.respond_raw(data.as_bytes()) {
                                            println!("Failed to send streaming data: {}", e);
                                            break;
                                        }
                                    }
                                }
                            } else {
                                // Handle non-JSON as raw output
                                let current_time = SystemTime::now()
                                    .duration_since(SystemTime::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs_f64();
                                let cast_event =
                                    serde_json::json!([current_time - start_time, "o", line]);
                                let data = format!(
                                    "data: {}

",
                                    cast_event
                                );
                                if let Err(e) = req.respond_raw(data.as_bytes()) {
                                    println!("Failed to send raw streaming data: {}", e);
                                    break;
                                }
                            }
                        }
                        Err(e) => {
                            println!("Error reading from tail: {}", e);
                            break;
                        }
                    }
                }

                // Clean up
                let _ = child.kill();
            }
        }
        Err(e) => {
            println!("Failed to start tail command: {}", e);
            let error_data = format!(
                "data: {{\"type\":\"error\",\"message\":\"Failed to start streaming: {}\"}}

",
                e
            );
            let _ = req.respond_raw(error_data.as_bytes());
        }
    }

    // Send end marker
    let end_data = "data: {\"type\":\"end\"}

";
    let _ = req.respond_raw(end_data.as_bytes());

    println!("Ended streaming SSE for session {}", session_id);
}

fn handle_stream_all_sessions(control_path: &PathBuf, req: &mut HttpRequest) {
    println!("Starting streaming SSE for all sessions");

    // Send SSE headers
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "text/event-stream")
        .header("Cache-Control", "no-cache")
        .header("Connection", "keep-alive")
        .header("Access-Control-Allow-Origin", "*")
        .body(Vec::new())
        .unwrap();

    if let Err(e) = req.respond(response) {
        println!("Failed to send SSE headers: {}", e);
        return;
    }

    let start_time = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    // Channel for coordinating writes from multiple threads
    let (tx, rx) = mpsc::channel::<String>();

    // Keep track of session threads for cleanup
    let mut session_threads = HashMap::new();
    let mut watcher_opt: Option<RecommendedWatcher> = None;
    let tracked_sessions = Arc::new(Mutex::new(HashMap::new()));

    // Get initial sessions and send their historical data
    let initial_sessions = match sessions::list_sessions(control_path) {
        Ok(sessions) => sessions,
        Err(e) => {
            let error_data = format!(
                "data: {{\"type\":\"error\",\"message\":\"Failed to list sessions: {}\"}}

",
                e
            );
            let _ = req.respond_raw(error_data.as_bytes());
            return;
        }
    };

    // Send default header first
    let default_header = serde_json::json!({
        "version": 2,
        "width": 80,
        "height": 24,
        "timestamp": start_time as u64,
        "env": { "TERM": "xterm" }
    });
    let header_data = format!(
        "data: {}

",
        default_header
    );
    if let Err(e) = req.respond_raw(header_data.as_bytes()) {
        println!("Failed to send header: {}", e);
        return;
    }

    // Send historical data for all sessions
    for (session_id, session_entry) in &initial_sessions {
        send_session_history(&session_entry.stream_out, session_id, &tx);
    }

    // Start threads for each existing session
    for (session_id, session_entry) in &initial_sessions {
        let tx_clone = tx.clone();
        let session_id_clone = session_id.clone();
        let stream_path = session_entry.stream_out.clone();

        let handle = thread::spawn(move || {
            stream_session_continuously(&stream_path, &session_id_clone, tx_clone);
        });

        session_threads.insert(session_id.clone(), handle);
        if let Ok(mut sessions) = tracked_sessions.lock() {
            sessions.insert(session_id.clone(), true);
        }
    }

    // Set up filesystem watcher for new sessions
    let control_path_clone = control_path.clone();
    let tx_watcher = tx.clone();
    let sessions_watcher = tracked_sessions.clone();

    match notify::recommended_watcher(move |res: Result<Event, notify::Error>| {
        match res {
            Ok(event) => {
                if let EventKind::Create(_) = event.kind {
                    for path in event.paths {
                        if path.is_dir() && path.parent() == Some(&control_path_clone) {
                            if let Some(session_id) = path.file_name().and_then(|n| n.to_str()) {
                                // Check if we've already seen this session
                                let already_tracked = if let Ok(sessions) = sessions_watcher.lock()
                                {
                                    sessions.contains_key(session_id)
                                } else {
                                    false
                                };

                                if already_tracked {
                                    continue;
                                }

                                // Wait a bit for session.json to be created
                                thread::sleep(std::time::Duration::from_millis(100));

                                let session_path = path.join("session.json");
                                if session_path.exists() {
                                    let stream_out_path = path.join("stream-out");
                                    if stream_out_path.exists() {
                                        // Mark session as tracked to prevent duplicate processing
                                        if let Ok(mut sessions) = sessions_watcher.lock() {
                                            sessions.insert(session_id.to_string(), true);
                                        }

                                        // Send historical data for new session
                                        send_session_history(
                                            &stream_out_path.to_string_lossy(),
                                            session_id,
                                            &tx_watcher,
                                        );

                                        // Start streaming thread for new session
                                        let tx_new = tx_watcher.clone();
                                        let session_id_new = session_id.to_string();
                                        let stream_path_new =
                                            stream_out_path.to_string_lossy().to_string();

                                        thread::spawn(move || {
                                            stream_session_continuously(
                                                &stream_path_new,
                                                &session_id_new,
                                                tx_new,
                                            );
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Err(e) => println!("Watcher error: {:?}", e),
        }
    }) {
        Ok(mut watcher) => {
            if let Err(e) = watcher.watch(control_path, RecursiveMode::NonRecursive) {
                println!("Failed to watch control path: {}", e);
            } else {
                watcher_opt = Some(watcher);
            }
        }
        Err(e) => {
            println!("Failed to create watcher: {}", e);
        }
    }

    // Process messages from all session threads
    for msg in rx {
        if let Err(e) = req.respond_raw(msg.as_bytes()) {
            println!("Failed to send streaming data: {}", e);
            break;
        }
    }

    // Cleanup
    drop(watcher_opt);
    println!("Ended streaming SSE for all sessions");
}

fn send_session_history(stream_path: &str, session_id: &str, tx: &mpsc::Sender<String>) {
    if let Ok(content) = fs::read_to_string(stream_path) {
        for line in content.lines() {
            if line.trim().is_empty() {
                continue;
            }

            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) {
                // Skip headers in historical data
                if parsed.get("version").is_some() && parsed.get("width").is_some() {
                    continue;
                }

                // Process event lines [timestamp, type, data]
                if let Some(arr) = parsed.as_array() {
                    if arr.len() >= 3 {
                        // Convert to instant event with session_id prefix
                        let instant_event = serde_json::json!([0, arr[1], arr[2]]);
                        let prefixed_data = format!(
                            "data: {}:{}

",
                            session_id, instant_event
                        );
                        let _ = tx.send(prefixed_data);
                    }
                }
            }
        }
    }
}

fn stream_session_continuously(stream_path: &str, session_id: &str, tx: mpsc::Sender<String>) {
    let start_time = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    // Use tail -f to stream new content
    match Command::new("tail")
        .args(&["-f", stream_path])
        .stdout(Stdio::piped())
        .spawn()
    {
        Ok(mut child) => {
            if let Some(stdout) = child.stdout.take() {
                let reader = BufReader::new(stdout);

                for line in reader.lines() {
                    match line {
                        Ok(line) => {
                            if line.trim().is_empty() {
                                continue;
                            }

                            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&line) {
                                // Skip headers in tail output
                                if parsed.get("version").is_some() && parsed.get("width").is_some()
                                {
                                    continue;
                                }

                                // Process event lines
                                if let Some(arr) = parsed.as_array() {
                                    if arr.len() >= 3 {
                                        let current_time = SystemTime::now()
                                            .duration_since(SystemTime::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_secs_f64();
                                        let real_time_event = serde_json::json!([
                                            current_time - start_time,
                                            arr[1],
                                            arr[2]
                                        ]);
                                        let prefixed_data = format!(
                                            "data: {}:{}

",
                                            session_id, real_time_event
                                        );
                                        if tx.send(prefixed_data).is_err() {
                                            break;
                                        }
                                    }
                                }
                            } else {
                                // Handle non-JSON as raw output
                                let current_time = SystemTime::now()
                                    .duration_since(SystemTime::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs_f64();
                                let cast_event =
                                    serde_json::json!([current_time - start_time, "o", line]);
                                let prefixed_data = format!(
                                    "data: {}:{}

",
                                    session_id, cast_event
                                );
                                if tx.send(prefixed_data).is_err() {
                                    break;
                                }
                            }
                        }
                        Err(e) => {
                            println!("Error reading from tail for session {}: {}", session_id, e);
                            break;
                        }
                    }
                }

                // Clean up
                let _ = child.kill();
            }
        }
        Err(e) => {
            println!(
                "Failed to start tail command for session {}: {}",
                session_id, e
            );
            let error_data = format!(
                "data: {}:{{\"type\":\"error\",\"message\":\"Failed to start streaming: {}\"}}

",
                session_id, e
            );
            let _ = tx.send(error_data);
        }
    }
}

fn handle_mkdir(req: &mut crate::http_server::HttpRequest) -> Response<String> {
    let body_bytes = req.body();
    let body = String::from_utf8_lossy(body_bytes);

    let mkdir_request = match serde_json::from_str::<MkdirRequest>(&body) {
        Ok(request) => request,
        Err(_) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Invalid request body. Expected JSON with 'path' field".to_string()),
                session_id: None,
            };
            return json_response(StatusCode::BAD_REQUEST, &error);
        }
    };

    if mkdir_request.path.is_empty() {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Path cannot be empty".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
    }

    match fs::create_dir_all(&mkdir_request.path) {
        Ok(_) => {
            let response = ApiResponse {
                success: Some(true),
                message: Some("Directory created successfully".to_string()),
                error: None,
                session_id: None,
            };
            json_response(StatusCode::OK, &response)
        }
        Err(e) => {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to create directory: {}", e)),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}
