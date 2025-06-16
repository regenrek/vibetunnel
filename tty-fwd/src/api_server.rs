use anyhow::Result;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::SystemTime;
use uuid::Uuid;

use crate::http_server::{HttpServer, Method, Response, StatusCode};
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

pub fn start_server(bind_address: &str, control_path: PathBuf) -> Result<()> {
    fs::create_dir_all(&control_path)?;

    let server = HttpServer::bind(bind_address)
        .map_err(|e| anyhow::anyhow!("Failed to bind server: {}", e))?;
    println!("HTTP API server listening on {}", bind_address);

    for req in server.incoming() {
        let control_path = control_path.clone();

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

            let response = match (method, path.as_str()) {
                (&Method::GET, "/api/sessions") => handle_list_sessions(&control_path),
                (&Method::POST, "/api/sessions") => handle_create_session(&control_path, &mut req),
                (&Method::POST, "/api/cleanup-exited") => handle_cleanup_exited(&control_path),
                (&Method::GET, path)
                    if path.starts_with("/api/sessions/") && path.ends_with("/stream") =>
                {
                    handle_session_stream(&control_path, &path)
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

            let _ = req.respond(response_to_bytes(response));
        });
    }

    Ok(())
}

fn extract_session_id(path: &str) -> Option<String> {
    let re = Regex::new(r"/api/sessions/([^/]+)").unwrap();
    re.captures(path)
        .and_then(|caps| caps.get(1))
        .map(|m| m.as_str().to_string())
}

fn response_to_bytes(response: Response<String>) -> Vec<u8> {
    let (parts, body) = response.into_parts();
    let status_line = format!(
        "HTTP/1.1 {} {}\r\n",
        parts.status.as_u16(),
        parts.status.canonical_reason().unwrap_or("")
    );
    let mut headers = String::new();
    for (name, value) in parts.headers {
        if let Some(name) = name {
            headers.push_str(&format!("{}: {}\r\n", name, value.to_str().unwrap_or("")));
        }
    }
    let response_str = format!("{}{}\r\n{}", status_line, headers, body);
    response_str.into_bytes()
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

fn handle_session_stream(control_path: &PathBuf, path: &str) -> Response<String> {
    if let Some(session_id) = extract_session_id(path) {
        // First check if the session exists using sessions::list_sessions
        let sessions = match sessions::list_sessions(control_path) {
            Ok(sessions) => sessions,
            Err(e) => {
                let error = ApiResponse {
                    success: None,
                    message: None,
                    error: Some(format!("Failed to list sessions: {}", e)),
                    session_id: None,
                };
                return json_response(StatusCode::INTERNAL_SERVER_ERROR, &error);
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
                return json_response(StatusCode::NOT_FOUND, &error);
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
            return json_response(StatusCode::NOT_FOUND, &error);
        }

        println!("Starting long-lived SSE stream for session {}", session_id);

        // This is a workaround for blocking-http-server's limitations
        // We'll use tail -f and keep the connection open for a reasonable time
        // The client should reconnect periodically to get fresh streams

        let start_time = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();

        let mut response_body = String::new();

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
                        response_body.push_str(&format!("data: {}\n\n", line));
                        header_sent = true;
                    }
                    // Check if this is an event line [timestamp, type, data]
                    else if parsed.as_array().map(|arr| arr.len() >= 3).unwrap_or(false) {
                        // Convert to instant event for immediate playback
                        if let Some(arr) = parsed.as_array() {
                            let instant_event = serde_json::json!([0, arr[1], arr[2]]);
                            response_body.push_str(&format!("data: {}\n\n", instant_event));
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
                response_body.push_str(&format!("data: {}\n\n", default_header));
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
            response_body.push_str(&format!("data: {}\n\n", default_header));
        }

        // Now use tail -f to get new content for a longer period
        // This provides a streaming-like experience within the constraints
        let stream_path_clone = stream_out_path.clone();

        match Command::new("tail")
            .args(&["-f", &stream_path_clone])
            .stdout(Stdio::piped())
            .spawn()
        {
            Ok(mut child) => {
                if let Some(stdout) = child.stdout.take() {
                    let reader = BufReader::new(stdout);

                    // Create a channel to communicate with the reader thread
                    let (tx, rx) = std::sync::mpsc::channel();

                    // Spawn thread to read from tail
                    let handle = thread::spawn(move || {
                        for line in reader.lines() {
                            if let Ok(line) = line {
                                if line.trim().is_empty() {
                                    continue;
                                }

                                if tx.send(line).is_err() {
                                    break; // Channel closed
                                }
                            }
                        }
                    });

                    // Collect new content for up to 10 seconds or until no new data
                    let timeout_duration = std::time::Duration::from_secs(10);
                    let poll_duration = std::time::Duration::from_millis(100);
                    let start_collect = std::time::Instant::now();
                    let mut last_data_time = start_collect;

                    while start_collect.elapsed() < timeout_duration {
                        match rx.recv_timeout(poll_duration) {
                            Ok(line) => {
                                last_data_time = std::time::Instant::now();

                                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&line)
                                {
                                    // Skip headers in tail output
                                    if parsed.get("version").is_some()
                                        && parsed.get("width").is_some()
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
                                            response_body.push_str(&format!(
                                                "data: {}\n\n",
                                                real_time_event
                                            ));
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
                                    response_body.push_str(&format!("data: {}\n\n", cast_event));
                                }
                            }
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                                // If no data for 2 seconds, consider ending the stream
                                if last_data_time.elapsed() > std::time::Duration::from_secs(2) {
                                    break;
                                }
                            }
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                break;
                            }
                        }
                    }

                    // Clean up
                    let _ = child.kill();
                    let _ = handle.join();
                }
            }
            Err(e) => {
                println!("Failed to start tail command: {}", e);
            }
        }

        // Send a final "end of stream" marker
        response_body.push_str("data: {\"type\":\"end\"}\n\n");

        // Return the SSE response
        Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", "text/event-stream")
            .header("Cache-Control", "no-cache")
            .header("Connection", "keep-alive")
            .header("Access-Control-Allow-Origin", "*")
            .header("Access-Control-Allow-Headers", "Cache-Control")
            .body(response_body)
            .unwrap()
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
