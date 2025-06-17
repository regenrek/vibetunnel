use anyhow::Result;
use data_encoding::BASE64;
use jiff::Timestamp;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime};
use uuid::Uuid;

use crate::http_server::{
    HttpRequest, HttpServer, Method, Response, SseResponseHelper, StatusCode,
};
use crate::protocol::{StreamEvent, StreamingIterator};
use crate::sessions;
use crate::tty_spawn::DEFAULT_TERM;

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
    #[serde(default = "default_true")]
    spawn_terminal: bool,
}

fn default_term_value() -> String {
    DEFAULT_TERM.to_string()
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
struct InputRequest {
    text: String,
}

#[derive(Debug, Deserialize)]
struct MkdirRequest {
    path: String,
}

#[derive(Debug, Deserialize)]
struct BrowseQuery {
    path: Option<String>,
}

#[derive(Debug, Serialize)]
struct FileInfo {
    name: String,
    created: String,
    #[serde(rename = "lastModified")]
    last_modified: String,
    size: u64,
    #[serde(rename = "isDir")]
    is_dir: bool,
}

#[derive(Debug, Serialize)]
struct BrowseResponse {
    #[serde(rename = "absolutePath")]
    absolute_path: String,
    files: Vec<FileInfo>,
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
        Some("html" | "htm") => "text/html",
        Some("css") => "text/css",
        Some("js" | "mjs") => "application/javascript",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
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
        if let Ok(content) = fs::read(&file_path) {
            let mime_type = get_mime_type(&file_path);

            Some(
                Response::builder()
                    .status(StatusCode::OK)
                    .header("Content-Type", mime_type)
                    .header("Access-Control-Allow-Origin", "*")
                    .body(content)
                    .unwrap(),
            )
        } else {
            let error_msg = b"Failed to read file".to_vec();
            Some(
                Response::builder()
                    .status(StatusCode::INTERNAL_SERVER_ERROR)
                    .header("Content-Type", "text/plain")
                    .body(error_msg)
                    .unwrap(),
            )
        }
    } else if file_path.is_dir() {
        // Try to serve index.html from the directory
        let index_path = file_path.join("index.html");
        println!("Checking for index.html at: {}", index_path.display());
        if index_path.is_file() {
            println!("Found index.html, serving it");
            if let Ok(content) = fs::read(&index_path) {
                Some(
                    Response::builder()
                        .status(StatusCode::OK)
                        .header("Content-Type", "text/html")
                        .header("Access-Control-Allow-Origin", "*")
                        .body(content)
                        .unwrap(),
                )
            } else {
                let error_msg = b"Failed to read index.html".to_vec();
                Some(
                    Response::builder()
                        .status(StatusCode::INTERNAL_SERVER_ERROR)
                        .header("Content-Type", "text/plain")
                        .body(error_msg)
                        .unwrap(),
                )
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
    vibetunnel_path: Option<String>,
) -> Result<()> {
    fs::create_dir_all(&control_path)?;

    let server = HttpServer::bind(bind_address)
        .map_err(|e| anyhow::anyhow!("Failed to bind server: {}", e))?;

    // Set up auth if password is provided
    let auth_password = if let Some(ref password) = password {
        println!(
            "HTTP API server listening on {bind_address} with Basic Auth enabled (any username)"
        );
        Some(password.clone())
    } else {
        println!("HTTP API server listening on {bind_address} with no authentication");
        None
    };

    for req in server.incoming() {
        let control_path = control_path.clone();
        let static_path = static_path.clone();
        let auth_password = auth_password.clone();
        let vibetunnel_path = vibetunnel_path.clone();

        thread::spawn(move || {
            let mut req = match req {
                Ok(req) => req,
                Err(e) => {
                    eprintln!("Request error: {e}");
                    return;
                }
            };

            let method = req.method();
            let path = req.uri().path().to_string();
            let full_uri = req.uri().to_string();

            println!("{method:?} {path} (full URI: {full_uri})");

            // Check authentication if enabled (but skip /api/health)
            if let Some(ref expected_password) = auth_password {
                if path != "/api/health" && !check_basic_auth(&req, expected_password) {
                    let _ = req.respond(unauthorized_response());
                    return;
                }
            }

            // Check for static file serving first
            if method == Method::GET && !path.starts_with("/api/") {
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
                (&Method::POST, "/api/sessions") => {
                    handle_create_session(&control_path, &req, vibetunnel_path.as_deref())
                }
                (&Method::POST, "/api/cleanup-exited") => handle_cleanup_exited(&control_path),
                (&Method::POST, "/api/mkdir") => handle_mkdir(&req),
                (&Method::GET, "/api/fs/browse") => handle_browse(&req),
                (&Method::GET, "/api/sessions/multistream") => {
                    return handle_multi_stream(&control_path, &mut req);
                }
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/stream") =>
                {
                    return handle_session_stream_direct(&control_path, path, &mut req);
                }
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/snapshot") =>
                {
                    handle_session_snapshot(&control_path, path)
                }
                (&Method::POST, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/input") =>
                {
                    handle_session_input(&control_path, path, &req)
                }
                (&Method::DELETE, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/cleanup") =>
                {
                    handle_session_cleanup(&control_path, path)
                }
                (&Method::DELETE, path) if path.starts_with("/api/sessions/") => {
                    handle_session_kill(&control_path, path)
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

fn handle_list_sessions(control_path: &Path) -> Response<String> {
    match sessions::list_sessions(control_path) {
        Ok(sessions) => {
            let mut session_responses = Vec::new();

            for (session_id, entry) in sessions {
                let started_at_str = entry
                    .session_info
                    .started_at
                    .map_or_else(|| "unknown".to_string(), |ts| ts.to_string());

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
                error: Some(format!("Failed to list sessions: {e}")),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}

fn handle_create_session(
    control_path: &Path,
    req: &crate::http_server::HttpRequest,
    vibetunnel_path: Option<&str>,
) -> Response<String> {
    // Read the request body
    let body_bytes = req.body();
    let body = String::from_utf8_lossy(body_bytes);

    let create_request = if let Ok(request) = serde_json::from_str::<CreateSessionRequest>(&body) {
        request
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid request body. Expected JSON with 'command' array and optional 'workingDir'".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
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

    // Handle terminal spawning if requested
    if create_request.spawn_terminal {
        match crate::term::spawn_terminal_command(
            &create_request.command,
            create_request.working_dir.as_deref(),
            vibetunnel_path,
        ) {
            Ok(terminal_session_id) => {
                println!("Terminal spawned with session ID: {}", terminal_session_id);
                let response = ApiResponse {
                    success: Some(true),
                    message: Some("Terminal spawned successfully".to_string()),
                    error: None,
                    session_id: Some(terminal_session_id),
                };
                return json_response(StatusCode::OK, &response);
            }
            Err(e) => {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some(format!("Failed to spawn terminal: {e}")),
                    session_id: None,
                };
                return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
            }
        }
    }

    // Create session directory
    let session_id = Uuid::new_v4().to_string();
    let session_path = control_path.join(&session_id);
    if let Err(e) = fs::create_dir_all(&session_path) {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some(format!("Failed to create session directory: {e}")),
            session_id: None,
        };
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
    }

    // Paths are set up within the spawned thread

    // Convert command to OsString vector
    let cmdline: Vec<std::ffi::OsString> = create_request
        .command
        .iter()
        .map(std::ffi::OsString::from)
        .collect();

    // Set working directory if specified, with tilde expansion
    let current_dir = if let Some(ref working_dir) = create_request.working_dir {
        // Expand ~ to home directory if needed
        let expanded_dir = if let Some(remaining_path) = working_dir.strip_prefix('~') {
            if let Some(home_dir) = std::env::var_os("HOME") {
                let home_path = std::path::Path::new(&home_dir);
                // Remove the ~ character
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
            .map_or_else(|_| "/".to_string(), |p| p.to_string_lossy().to_string())
    };

    // Spawn the process in a detached manner using a separate thread
    let control_path_clone = control_path.to_path_buf();
    let session_id_clone = session_id.clone();
    let cmdline_clone = cmdline;
    let working_dir_clone = current_dir;
    let term_clone = create_request.term;

    std::thread::Builder::new()
        .name(format!("session-{session_id_clone}"))
        .spawn(move || {
            // Change to the specified working directory before spawning
            let original_dir = std::env::current_dir().ok();
            if let Err(e) = std::env::set_current_dir(&working_dir_clone) {
                eprintln!("Failed to change to working directory {working_dir_clone}: {e}");
                return;
            }

            // Set up TtySpawn
            let mut tty_spawn = crate::tty_spawn::TtySpawn::new_cmdline(
                cmdline_clone.iter().map(std::ffi::OsString::as_os_str),
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
                eprintln!("Failed to set up TTY paths for session {session_id_clone}: {e}");
                return;
            }

            tty_spawn.session_json_path(&session_info_path);

            if let Err(e) = tty_spawn.notification_path(&notification_stream_path) {
                eprintln!("Failed to set up notification path for session {session_id_clone}: {e}");
                return;
            }

            // Set session name based on the first command
            let session_name = cmdline_clone
                .first()
                .and_then(|cmd| cmd.to_str())
                .map_or("unknown", |s| s.split('/').next_back().unwrap_or(s))
                .to_string();
            tty_spawn.session_name(session_name);

            // Set the TERM environment variable
            tty_spawn.term(term_clone);

            // Enable detached mode for API-created sessions
            tty_spawn.detached(true);

            // Spawn the process (this will block until the process exits)
            match tty_spawn.spawn() {
                Ok(exit_code) => {
                    println!("Session {session_id_clone} exited with code {exit_code}");
                }
                Err(e) => {
                    eprintln!("Failed to spawn session {session_id_clone}: {e}");
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

fn handle_cleanup_exited(control_path: &Path) -> Response<String> {
    match sessions::cleanup_sessions(control_path, None) {
        Ok(()) => {
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
                error: Some(format!("Failed to cleanup sessions: {e}")),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}

fn handle_session_snapshot(control_path: &Path, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        let stream_path = control_path.join(&session_id).join("stream-out");

        if let Ok(content) = fs::read_to_string(&stream_path) {
            Response::builder()
                .status(StatusCode::OK)
                .header("Content-Type", "text/plain")
                .body(content)
                .unwrap()
        } else {
            let error = ApiResponse {
                success: None,
                message: None,
                error: Some("Session not found".to_string()),
                session_id: None,
            };
            json_response(StatusCode::NOT_FOUND, &error)
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
    control_path: &Path,
    path: &str,
    req: &crate::http_server::HttpRequest,
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
                            Ok(()) => {
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
                                    error: Some(format!("Failed to send input: {e}")),
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
                        error: Some(format!("Failed to list sessions: {e}")),
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

fn handle_session_kill(control_path: &Path, path: &str) -> Response<String> {
    let session_id = if let Some(id) = extract_session_id(path) {
        id
    } else {
        let response = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid session ID".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &response);
    };

    let sessions = match sessions::list_sessions(control_path) {
        Ok(sessions) => sessions,
        Err(e) => {
            let response = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to list sessions: {e}")),
                session_id: None,
            };
            return json_response(StatusCode::INTERNAL_SERVER_ERROR, &response);
        }
    };

    let session_entry = if let Some(entry) = sessions.get(&session_id) {
        entry
    } else {
        let response = ApiResponse {
            success: None,
            message: None,
            error: Some("Session not found".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::NOT_FOUND, &response);
    };

    // If session has no PID, consider it already dead
    if session_entry.session_info.pid.is_none() {
        let response = ApiResponse {
            success: Some(true),
            message: Some("Session killed".to_string()),
            error: None,
            session_id: None,
        };
        return json_response(StatusCode::OK, &response);
    }

    // Try SIGKILL first, then SIGKILL if needed
    let (status, message) = match sessions::send_signal_to_session(control_path, &session_id, 9) {
        Ok(()) => (StatusCode::OK, "Session killed (SIGKILL)"),
        Err(e) => {
            let response = ApiResponse {
                success: None,
                message: None,
                error: Some(format!("Failed to kill session: {e}")),
                session_id: None,
            };
            return json_response(StatusCode::GONE, &response);
        }
    };

    let response = ApiResponse {
        success: Some(true),
        message: Some(message.to_string()),
        error: None,
        session_id: None,
    };
    json_response(status, &response)
}

fn handle_session_cleanup(control_path: &Path, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        match sessions::cleanup_sessions(control_path, Some(&session_id)) {
            Ok(()) => {
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
                    error: Some(format!("Failed to cleanup session: {e}")),
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

fn handle_session_stream_direct(control_path: &Path, path: &str, req: &mut HttpRequest) {
    let sessions = sessions::list_sessions(control_path).expect("Failed to list sessions");

    // Extract session ID and find the corresponding entry
    let Some((session_id, session_entry)) =
        extract_session_id(path).and_then(|id| sessions.get(&id).map(|entry| (id, entry)))
    else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Session not found".to_string()),
            session_id: None,
        };
        let response = json_response(StatusCode::NOT_FOUND, &error);
        let _ = req.respond(response);
        return;
    };

    println!("Starting streaming SSE for session {session_id}");

    // Initialize SSE response helper
    let mut sse_helper = match SseResponseHelper::new(req) {
        Ok(helper) => helper,
        Err(e) => {
            println!("Failed to initialize SSE helper: {e}");
            return;
        }
    };

    // Process events from the channel and send as SSE
    for event in StreamingIterator::new(session_entry.stream_out.clone()) {
        // Log errors for debugging
        if let StreamEvent::Error { message } = &event {
            println!("Stream error: {message}");
            break;
        }

        // Serialize and send the event as SSE data
        if let Ok(event_json) = serde_json::to_string(&event) {
            if let Err(e) = sse_helper.write_event(&event_json) {
                println!("Failed to send SSE data: {e}");
                break;
            }
        }

        // Break on End event
        if matches!(event, StreamEvent::End) {
            break;
        }
    }

    println!("Ended streaming SSE for session {session_id}");
}

fn handle_multi_stream(control_path: &Path, req: &mut HttpRequest) {
    println!("Starting multiplex streaming with dynamic session discovery");

    // Initialize SSE response helper
    let mut sse_helper = match SseResponseHelper::new(req) {
        Ok(helper) => helper,
        Err(e) => {
            println!("Failed to initialize SSE helper: {e}");
            return;
        }
    };

    // Create channels for communication
    let (sender, receiver) = mpsc::sync_channel::<(String, StreamEvent)>(100);
    let (session_discovery_tx, session_discovery_rx) = mpsc::channel::<String>();

    // Spawn session discovery thread to watch for new session directories
    let control_path_clone = control_path.to_path_buf();
    let discovery_sender = session_discovery_tx.clone();
    let session_discovery_handle = thread::spawn(move || {
        // Set up watcher for the control directory
        let (watcher_tx, watcher_rx) = mpsc::channel();
        let mut watcher: RecommendedWatcher = match notify::Watcher::new(
            move |res: notify::Result<Event>| {
                if let Ok(event) = res {
                    let _ = watcher_tx.send(event);
                }
            },
            notify::Config::default(),
        ) {
            Ok(w) => w,
            Err(e) => {
                println!("Failed to create session discovery watcher: {}", e);
                return;
            }
        };

        if let Err(e) = watcher.watch(&control_path_clone, RecursiveMode::NonRecursive) {
            println!(
                "Failed to watch control directory {:?}: {}",
                control_path_clone, e
            );
            return;
        }

        println!(
            "Session discovery thread started, watching {:?}",
            control_path_clone
        );

        // Also discover existing sessions at startup
        if let Ok(sessions) = sessions::list_sessions(&control_path_clone) {
            for session_id in sessions.keys() {
                if discovery_sender.send(session_id.clone()).is_err() {
                    println!("Failed to send initial session discovery");
                    return;
                }
            }
        }

        // Watch for new directories being created
        while let Ok(event) = watcher_rx.recv() {
            match event.kind {
                EventKind::Create(_) => {
                    for path in event.paths {
                        if path.is_dir() {
                            if let Some(session_id) = path.file_name().and_then(|n| n.to_str()) {
                                // Check if this looks like a session directory (has session.json)
                                let session_json_path = path.join("session.json");
                                if session_json_path.exists() {
                                    println!("New session directory detected: {}", session_id);
                                    if discovery_sender.send(session_id.to_string()).is_err() {
                                        println!("Session discovery channel closed");
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }

        println!("Session discovery thread ended");
    });

    // Spawn session manager thread to handle new sessions
    let control_path_clone2 = control_path.to_path_buf();
    let main_sender = sender.clone();
    let session_manager_handle = thread::spawn(move || {
        use std::collections::HashSet;
        let mut active_sessions = HashSet::new();
        let mut session_handles = Vec::new();

        while let Ok(session_id) = session_discovery_rx.recv() {
            // Skip if we already have this session
            if active_sessions.contains(&session_id) {
                continue;
            }

            // Get session info
            let sessions = match sessions::list_sessions(&control_path_clone2) {
                Ok(sessions) => sessions,
                Err(e) => {
                    println!("Failed to list sessions: {}", e);
                    continue;
                }
            };

            let session_entry = match sessions.get(&session_id) {
                Some(entry) => entry.clone(),
                None => {
                    println!("Session {} not found in session list", session_id);
                    continue;
                }
            };

            println!("Starting stream thread for new session: {}", session_id);
            active_sessions.insert(session_id.clone());

            // Spawn thread for this session
            let session_id_clone = session_id.clone();
            let stream_path = session_entry.stream_out.clone();
            let thread_sender = main_sender.clone();

            let handle = thread::spawn(move || {
                loop {
                    let stream = StreamingIterator::new(stream_path.clone());

                    println!("Starting stream for session {}", session_id_clone);

                    // Process events from this session's stream
                    for event in stream {
                        // Send event through channel
                        if thread_sender
                            .send((session_id_clone.clone(), event.clone()))
                            .is_err()
                        {
                            println!(
                                "Channel closed, ending stream thread for session {}",
                                session_id_clone
                            );
                            return;
                        }

                        // If this is an End event, the stream is finished
                        if matches!(event, StreamEvent::End) {
                            println!(
                                "Stream ended for session {}, waiting for file changes",
                                session_id_clone
                            );
                            break;
                        }
                    }

                    // Set up FS notify to watch for file recreation
                    let (watcher_tx, watcher_rx) = mpsc::channel();
                    let mut watcher: RecommendedWatcher = match notify::Watcher::new(
                        move |res: notify::Result<Event>| {
                            if let Ok(event) = res {
                                let _ = watcher_tx.send(event);
                            }
                        },
                        notify::Config::default(),
                    ) {
                        Ok(w) => w,
                        Err(e) => {
                            println!(
                                "Failed to create file watcher for session {}: {}",
                                session_id_clone, e
                            );
                            return;
                        }
                    };

                    // Watch the stream file's parent directory
                    let stream_path_buf = std::path::PathBuf::from(&stream_path);
                    let parent_dir = match stream_path_buf.parent() {
                        Some(parent) => parent,
                        None => {
                            println!("Cannot determine parent directory for {}", stream_path);
                            return;
                        }
                    };

                    if let Err(e) = watcher.watch(parent_dir, RecursiveMode::NonRecursive) {
                        println!(
                            "Failed to watch directory {:?} for session {}: {}",
                            parent_dir, session_id_clone, e
                        );
                        return;
                    }

                    // Wait for the file to be recreated or timeout
                    let mut file_recreated = false;
                    let timeout = Duration::from_secs(30);
                    let start_time = std::time::Instant::now();

                    while start_time.elapsed() < timeout {
                        if let Ok(event) = watcher_rx.recv_timeout(Duration::from_millis(100)) {
                            match event.kind {
                                EventKind::Create(_) | EventKind::Modify(_) => {
                                    for path in event.paths {
                                        if path.to_string_lossy() == stream_path {
                                            println!(
                                                "Stream file recreated for session {}",
                                                session_id_clone
                                            );
                                            file_recreated = true;
                                            break;
                                        }
                                    }
                                    if file_recreated {
                                        break;
                                    }
                                }
                                _ => {}
                            }
                        }

                        // Also check if file exists (in case we missed the event)
                        if std::path::Path::new(&stream_path).exists() {
                            file_recreated = true;
                            break;
                        }
                    }

                    if !file_recreated {
                        println!(
                            "Timeout waiting for stream file recreation for session {}, ending thread",
                            session_id_clone
                        );
                        return;
                    }

                    // Small delay before restarting to ensure file is ready
                    std::thread::sleep(Duration::from_millis(100));
                }
            });

            session_handles.push((session_id.clone(), handle));
        }

        println!(
            "Session manager thread ended, waiting for {} session threads",
            session_handles.len()
        );

        // Wait for all session threads to finish
        for (session_id, handle) in session_handles {
            println!("Waiting for session thread {} to finish", session_id);
            let _ = handle.join();
        }

        println!("All session threads finished");
    });

    // Drop original senders so channels close when threads finish
    drop(sender);
    drop(session_discovery_tx);

    // Process events from the channel and send as SSE
    while let Ok((session_id, event)) = receiver.recv() {
        // Log errors for debugging
        if let StreamEvent::Error { message } = &event {
            println!("Stream error for session {session_id}: {message}");
            continue;
        }

        // Serialize the normal event
        if let Ok(event_json) = serde_json::to_string(&event) {
            // Create the prefixed format: session_id:serialized_normal_event
            let prefixed_event = format!("{}:{}", session_id, event_json);

            // Send as SSE data
            if let Err(e) = sse_helper.write_event(&prefixed_event) {
                println!("Failed to send SSE data: {e}");
                break;
            }
        }
    }

    println!("Multiplex streaming ended, cleaning up threads");

    // Wait for discovery and manager threads to finish
    let _ = session_discovery_handle.join();
    let _ = session_manager_handle.join();

    println!("All threads finished");
}

fn resolve_path(path: &str, home_dir: &str) -> PathBuf {
    if path.starts_with('~') {
        if path == "~" {
            PathBuf::from(home_dir)
        } else {
            PathBuf::from(home_dir).join(&path[2..]) // Skip ~/
        }
    } else {
        PathBuf::from(path)
    }
}

fn handle_browse(req: &crate::http_server::HttpRequest) -> Response<String> {
    let query_string = req.uri().query().unwrap_or("");

    let query: BrowseQuery = if let Ok(query) = serde_urlencoded::from_str(query_string) {
        query
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid query parameters".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
    };

    let dir_path = query.path.as_deref().unwrap_or("~");

    // Get home directory
    let home_dir = std::env::var("HOME").unwrap_or_else(|_| "/".to_string());
    let expanded_path = resolve_path(dir_path, &home_dir);

    if !expanded_path.exists() {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Directory not found".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::NOT_FOUND, &error);
    }

    let metadata = if let Ok(metadata) = fs::metadata(&expanded_path) {
        metadata
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Failed to read directory metadata".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
    };

    if !metadata.is_dir() {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Path is not a directory".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
    }

    let entries = if let Ok(entries) = fs::read_dir(&expanded_path) {
        entries
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Failed to list directory".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
    };

    let mut files = Vec::new();
    for entry in entries.flatten() {
        if let Ok(file_metadata) = entry.metadata() {
            let name = entry.file_name().to_string_lossy().to_string();

            fn system_time_to_iso_string(time: SystemTime) -> String {
                let duration = time
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap_or_default();
                let timestamp = Timestamp::from_second(duration.as_secs() as i64)
                    .unwrap_or(Timestamp::UNIX_EPOCH);
                timestamp.to_string()
            }

            let created = file_metadata
                .created()
                .or_else(|_| file_metadata.modified())
                .map_or_else(
                    |_| "1970-01-01T00:00:00Z".to_string(),
                    system_time_to_iso_string,
                );

            let last_modified = file_metadata.modified().map_or_else(
                |_| "1970-01-01T00:00:00Z".to_string(),
                system_time_to_iso_string,
            );

            files.push(FileInfo {
                name,
                created,
                last_modified,
                size: file_metadata.len(),
                is_dir: file_metadata.is_dir(),
            });
        }
    }

    // Sort: directories first, then files, alphabetically
    files.sort_by(|a, b| {
        if a.is_dir && !b.is_dir {
            std::cmp::Ordering::Less
        } else if !a.is_dir && b.is_dir {
            std::cmp::Ordering::Greater
        } else {
            a.name.cmp(&b.name)
        }
    });

    let response = BrowseResponse {
        absolute_path: expanded_path.to_string_lossy().to_string(),
        files,
    };

    json_response(StatusCode::OK, &response)
}

fn handle_mkdir(req: &crate::http_server::HttpRequest) -> Response<String> {
    let body_bytes = req.body();
    let body = String::from_utf8_lossy(body_bytes);

    let mkdir_request = if let Ok(request) = serde_json::from_str::<MkdirRequest>(&body) {
        request
    } else {
        let error = ApiResponse {
            success: None,
            message: None,
            error: Some("Invalid request body. Expected JSON with 'path' field".to_string()),
            session_id: None,
        };
        return json_response(StatusCode::BAD_REQUEST, &error);
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
        Ok(()) => {
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
                error: Some(format!("Failed to create directory: {e}")),
                session_id: None,
            };
            json_response(StatusCode::INTERNAL_SERVER_ERROR, &error)
        }
    }
}
