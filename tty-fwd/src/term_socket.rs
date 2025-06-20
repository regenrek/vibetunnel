use crate::tty_spawn;
use anyhow::Result;
use serde_json::json;
use signal_hook::{
    consts::{SIGINT, SIGTERM},
    iterator::Signals,
};
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use uuid::Uuid;

/// Spawn a terminal session with PTY fallback
pub fn spawn_terminal_via_socket(command: &[String], working_dir: Option<&str>) -> Result<String> {
    // Try socket first
    match spawn_via_socket_impl(command, working_dir) {
        Ok(session_id) => Ok(session_id),
        Err(socket_err) => {
            eprintln!("Socket spawn failed ({socket_err}), falling back to PTY");
            spawn_via_pty(command, working_dir)
        }
    }
}

/// Spawn a terminal session by communicating with `VibeTunnel` via Unix socket
fn spawn_via_socket_impl(command: &[String], working_dir: Option<&str>) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();
    let socket_path = "/tmp/vibetunnel-terminal.sock";

    // Try to connect to the Unix socket
    let mut stream = match UnixStream::connect(socket_path) {
        Ok(stream) => stream,
        Err(e) => {
            return Err(anyhow::anyhow!(
                "Terminal spawn service not available at {}: {}",
                socket_path,
                e
            ));
        }
    };

    // Get the current tty-fwd binary path
    let tty_fwd_path = env::current_exe().map_or_else(
        |_| "tty-fwd".to_string(),
        |p| p.to_string_lossy().to_string(),
    );

    // Pre-format the command with proper escaping
    // This reduces complexity in Swift and avoids double-escaping issues
    // tty-fwd reads session ID from TTY_SESSION_ID environment variable
    let formatted_command = format!(
        "TTY_SESSION_ID=\"{}\" {} -- {}",
        session_id,
        tty_fwd_path,
        shell_words::join(command)
    );

    // Construct the spawn request with optimized format
    let request = json!({
        "command": formatted_command,
        "workingDir": working_dir.unwrap_or("~/"),
        "sessionId": session_id,
        "ttyFwdPath": tty_fwd_path,
        "terminal": std::env::var("VIBETUNNEL_TERMINAL").ok()
    });

    let request_data = serde_json::to_vec(&request)?;

    // Send the request
    stream.write_all(&request_data)?;
    stream.flush()?;

    // Read the response
    let mut response_data = Vec::new();
    stream.read_to_end(&mut response_data)?;

    // Parse the response
    #[derive(serde::Deserialize)]
    struct SpawnResponse {
        success: bool,
        error: Option<String>,
        #[serde(rename = "sessionId")]
        #[allow(dead_code)]
        session_id: Option<String>,
    }

    let response: SpawnResponse = serde_json::from_slice(&response_data)?;

    if response.success {
        Ok(session_id)
    } else {
        let error_msg = response
            .error
            .unwrap_or_else(|| "Unknown error".to_string());
        Err(anyhow::anyhow!("Failed to spawn terminal: {}", error_msg))
    }
}

/// Spawn a terminal session using PTY directly (fallback)
fn spawn_via_pty(command: &[String], working_dir: Option<&str>) -> Result<String> {
    tty_spawn::spawn_with_pty_fallback(command, working_dir).map_err(|e| anyhow::anyhow!("{}", e))
}

/// Update all running sessions to "exited" status when server shuts down
pub fn update_all_sessions_to_exited() -> Result<()> {
    let control_dir = env::var("TTY_FWD_CONTROL_DIR").unwrap_or_else(|_| {
        format!(
            "{}/.vibetunnel/control",
            env::var("HOME").unwrap_or_default()
        )
    });

    if !std::path::Path::new(&control_dir).exists() {
        return Ok(());
    }

    for entry in std::fs::read_dir(&control_dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            let session_json_path = path.join("session.json");
            if session_json_path.exists() {
                // Read current session info
                if let Ok(content) = std::fs::read_to_string(&session_json_path) {
                    if let Ok(mut session_info) =
                        serde_json::from_str::<serde_json::Value>(&content)
                    {
                        // Update status to exited if it was running
                        if let Some(status) = session_info.get("status").and_then(|s| s.as_str()) {
                            if status == "running" {
                                session_info["status"] = json!("exited");
                                // Write back the updated session info
                                if let Ok(updated_content) =
                                    serde_json::to_string_pretty(&session_info)
                                {
                                    let _ = std::fs::write(&session_json_path, updated_content);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(())
}

/// Setup signal handler to cleanup sessions on shutdown
pub fn setup_shutdown_handler() {
    std::thread::spawn(move || {
        let mut signals =
            Signals::new([SIGTERM, SIGINT]).expect("Failed to create signals iterator");

        if let Some(sig) = signals.forever().next() {
            eprintln!("Received signal {sig:?}, updating session statuses...");
            if let Err(e) = update_all_sessions_to_exited() {
                eprintln!("Failed to update session statuses: {e}");
            }
        }
    });
}
