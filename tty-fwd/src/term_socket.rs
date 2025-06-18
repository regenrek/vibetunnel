use anyhow::Result;
use serde_json::json;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use uuid::Uuid;
use std::env;

/// Spawn a terminal session by communicating with VibeTunnel via Unix socket
pub fn spawn_terminal_via_socket(
    command: &[String],
    working_dir: Option<&str>,
) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();
    let socket_path = "/tmp/vibetunnel-terminal.sock";

    // Try to connect to the Unix socket
    let mut stream = match UnixStream::connect(socket_path) {
        Ok(stream) => stream,
        Err(e) => {
            return Err(anyhow::anyhow!("Terminal spawn service not available at {}: {}", socket_path, e));
        }
    };
    
    // Get the current tty-fwd binary path
    let tty_fwd_path = env::current_exe()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "tty-fwd".to_string());
    
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
        let error_msg = response.error.unwrap_or_else(|| "Unknown error".to_string());
        Err(anyhow::anyhow!("Failed to spawn terminal: {}", error_msg))
    }
}