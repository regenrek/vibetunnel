use anyhow::Result;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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
}

#[derive(Debug, Deserialize)]
struct InputRequest {
    text: String,
}

#[derive(Debug, Serialize)]
struct ApiResponse {
    success: Option<bool>,
    message: Option<String>,
    error: Option<String>,
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
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
    
    // Security check: ensure the file path is within the static root
    if !file_path.starts_with(static_root) {
        return None;
    }
    
    if file_path.is_file() {
        // Serve the file directly
        match fs::read(&file_path) {
            Ok(content) => {
                let mime_type = get_mime_type(&file_path);
                
                Some(Response::builder()
                    .status(StatusCode::OK)
                    .header("Content-Type", mime_type)
                    .header("Access-Control-Allow-Origin", "*")
                    .body(content)
                    .unwrap())
            }
            Err(_) => {
                let error_msg = "Failed to read file".as_bytes().to_vec();
                Some(Response::builder()
                    .status(StatusCode::INTERNAL_SERVER_ERROR)
                    .header("Content-Type", "text/plain")
                    .body(error_msg)
                    .unwrap())
            }
        }
    } else if file_path.is_dir() {
        // Try to serve index.html from the directory
        let index_path = file_path.join("index.html");
        if index_path.is_file() {
            match fs::read(&index_path) {
                Ok(content) => {
                    Some(Response::builder()
                        .status(StatusCode::OK)
                        .header("Content-Type", "text/html")
                        .header("Access-Control-Allow-Origin", "*")
                        .body(content)
                        .unwrap())
                }
                Err(_) => {
                    let error_msg = "Failed to read index.html".as_bytes().to_vec();
                    Some(Response::builder()
                        .status(StatusCode::INTERNAL_SERVER_ERROR)
                        .header("Content-Type", "text/plain")
                        .body(error_msg)
                        .unwrap())
                }
            }
        } else {
            None // Directory doesn't have index.html
        }
    } else {
        None // File doesn't exist
    }
}

pub fn start_server(bind_address: &str, control_path: PathBuf, static_path: Option<String>) -> Result<()> {
    fs::create_dir_all(&control_path)?;

    let server = HttpServer::bind(bind_address)
        .map_err(|e| anyhow::anyhow!("Failed to bind server: {}", e))?;
    println!("HTTP API server listening on {}", bind_address);

    for req in server.incoming() {
        let control_path = control_path.clone();
        let static_path = static_path.clone();

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

            println!("{:?} {}", method, path);

            // Check for static file serving first
            if method == &Method::GET && !path.starts_with("/api/") {
                if let Some(ref static_dir) = static_path {
                    let static_dir_path = Path::new(static_dir);
                    if static_dir_path.exists() && static_dir_path.is_dir() {
                        if let Some(static_response) = serve_static_file(static_dir_path, &path) {
                            let _ = req.respond(static_response);
                            return;
                        }
                    }
                }
            }

            let response = match (method, path.as_str()) {
                (&Method::GET, "/api/sessions") => handle_list_sessions(&control_path),
                (&Method::POST, "/api/sessions") => handle_create_session(&control_path, &mut req),
                (&Method::POST, "/api/cleanup-exited") => handle_cleanup_exited(&control_path),
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/stream") =>
                {
                    // Handle streaming differently - bypass normal response handling
                    handle_session_stream_direct(&control_path, &path, &mut req);
                    return; // Skip the normal response handling
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
    let re = Regex::new(r"/api/sessions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})").unwrap();
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
    _control_path: &PathBuf,
    _req: &mut crate::http_server::HttpRequest,
) -> Response<String> {
    // For now, return a stub response since reading request body is complex
    let session_id = Uuid::new_v4().to_string();
    let response = ApiResponse {
        success: None,
        message: Some("Session creation stubbed".to_string()),
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
            match sessions::send_text_to_session(control_path, &session_id, &input_req.text) {
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
        match sessions::send_signal_to_session(control_path, &session_id, 9) {
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
                    let data = format!("data: {}

", line);
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
                        let data = format!("data: {}

", instant_event);
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
                "env": { "TERM": "xterm-256color" }
            });
            let data = format!("data: {}

", default_header);
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
            "env": { "TERM": "xterm-256color" }
        });
        let data = format!("data: {}

", default_header);
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
                                if parsed.get("version").is_some() && parsed.get("width").is_some() {
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
                                        let data = format!("data: {}

", real_time_event);
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
                                let cast_event = serde_json::json!([current_time - start_time, "o", line]);
                                let data = format!("data: {}

", cast_event);
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
            let error_data = format!("data: {{\"type\":\"error\",\"message\":\"Failed to start streaming: {}\"}}

", e);
            let _ = req.respond_raw(error_data.as_bytes());
        }
    }

    // Send end marker
    let end_data = "data: {\"type\":\"end\"}

";
    let _ = req.respond_raw(end_data.as_bytes());
    
    println!("Ended streaming SSE for session {}", session_id);
}
