use anyhow::anyhow;
use std::collections::HashMap;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::process::Command;

use crate::protocol::{SessionInfo, SessionListEntry};

pub fn list_sessions(
    control_path: &Path,
) -> Result<HashMap<String, SessionListEntry>, anyhow::Error> {
    let mut sessions = HashMap::new();

    if !control_path.exists() {
        return Ok(sessions);
    }

    for entry in fs::read_dir(control_path)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            let session_id = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            let session_json_path = path.join("session.json");
            let stream_out_path = path.join("stream-out");
            let stdin_path = path.join("stdin");
            let notification_stream_path = path.join("notification-stream");

            if session_json_path.exists() {
                let stream_out = stream_out_path
                    .canonicalize()
                    .unwrap_or(stream_out_path.clone())
                    .to_string_lossy()
                    .to_string();
                let stdin = stdin_path
                    .canonicalize()
                    .unwrap_or(stdin_path.clone())
                    .to_string_lossy()
                    .to_string();
                let notification_stream = notification_stream_path
                    .canonicalize()
                    .unwrap_or(notification_stream_path.clone())
                    .to_string_lossy()
                    .to_string();
                let session_info = fs::read_to_string(&session_json_path)
                    .and_then(|content| serde_json::from_str(&content).map_err(Into::into))
                    .unwrap_or_default();

                sessions.insert(
                    session_id.to_string(),
                    SessionListEntry {
                        session_info,
                        stream_out,
                        stdin,
                        notification_stream,
                    },
                );
            }
        }
    }

    Ok(sessions)
}

pub fn send_key_to_session(
    control_path: &Path,
    session_id: &str,
    key: &str,
) -> Result<(), anyhow::Error> {
    let session_path = control_path.join(session_id);
    let stdin_path = session_path.join("stdin");

    if !stdin_path.exists() {
        return Err(anyhow!("Session {} not found or not running", session_id));
    }

    let key_bytes: &[u8] = match key {
        "arrow_up" => b"\x1b[A",
        "arrow_down" => b"\x1b[B",
        "arrow_right" => b"\x1b[C",
        "arrow_left" => b"\x1b[D",
        "escape" => b"\x1b",
        "enter" => b"\r",
        "ctrl_enter" => b"\x0d", // Just CR like normal enter for now - let's test this first
        "shift_enter" => b"\x1b\x0d", // ESC + Enter - simpler approach
        _ => return Err(anyhow!("Unknown key: {}", key)),
    };

    let mut file = OpenOptions::new().append(true).open(&stdin_path)?;
    file.write_all(key_bytes)?;
    file.flush()?;

    Ok(())
}

pub fn send_text_to_session(
    control_path: &Path,
    session_id: &str,
    text: &str,
) -> Result<(), anyhow::Error> {
    let session_path = control_path.join(session_id);
    let stdin_path = session_path.join("stdin");

    if !stdin_path.exists() {
        return Err(anyhow!("Session {} not found or not running", session_id));
    }

    let mut file = OpenOptions::new().append(true).open(&stdin_path)?;
    file.write_all(text.as_bytes())?;
    file.flush()?;

    Ok(())
}

fn is_pid_alive(pid: u32) -> bool {
    let output = Command::new("ps").arg("-p").arg(pid.to_string()).output();

    match output {
        Ok(output) => output.status.success(),
        Err(_) => false,
    }
}

pub fn send_signal_to_session(
    control_path: &Path,
    session_id: &str,
    signal: i32,
) -> Result<(), anyhow::Error> {
    let session_path = control_path.join(session_id);
    let session_json_path = session_path.join("session.json");

    if !session_json_path.exists() {
        return Err(anyhow!("Session {} not found", session_id));
    }

    let content = fs::read_to_string(&session_json_path)?;
    let session_info: SessionInfo = serde_json::from_str(&content)?;

    if let Some(pid) = session_info.pid {
        if is_pid_alive(pid) {
            let result = unsafe { libc::kill(pid as i32, signal) };
            if result == 0 {
                Ok(())
            } else {
                Err(anyhow!("Failed to send signal {} to PID {}", signal, pid))
            }
        } else {
            Err(anyhow!(
                "Session {} process (PID: {}) is not running",
                session_id,
                pid
            ))
        }
    } else {
        Err(anyhow!("Session {} has no PID recorded", session_id))
    }
}

fn cleanup_session(control_path: &Path, session_id: &str) -> Result<bool, anyhow::Error> {
    let session_path = control_path.join(session_id);
    let session_json_path = session_path.join("session.json");

    if !session_path.exists() {
        return Err(anyhow!("Session {} not found", session_id));
    }

    if session_json_path.exists() {
        let content = fs::read_to_string(&session_json_path)?;
        if let Ok(session_info) = serde_json::from_str::<SessionInfo>(&content) {
            if let Some(pid) = session_info.pid {
                if is_pid_alive(pid) {
                    return Err(anyhow!(
                        "Session {} is still running (PID: {})",
                        session_id,
                        pid
                    ));
                }
            }
        }
    }

    fs::remove_dir_all(&session_path)?;
    Ok(true)
}

pub fn cleanup_sessions(
    control_path: &Path,
    specific_session: Option<&str>,
) -> Result<(), anyhow::Error> {
    if !control_path.exists() {
        return Ok(());
    }

    if let Some(session_id) = specific_session {
        cleanup_session(control_path, session_id)?;
        return Ok(());
    }

    for entry in fs::read_dir(control_path)? {
        let entry = entry?;
        let path = entry.path();

        if !path.is_dir() {
            continue;
        }

        if let Some(_session_id) = path.file_name().and_then(|n| n.to_str()) {
            let session_json_path = path.join("session.json");
            if !session_json_path.exists() {
                continue;
            }

            let should_remove = if let Ok(content) = fs::read_to_string(&session_json_path) {
                if let Ok(session_info) = serde_json::from_str::<SessionInfo>(&content) {
                    if let Some(pid) = session_info.pid {
                        !is_pid_alive(pid)
                    } else {
                        true
                    }
                } else {
                    true
                }
            } else {
                true
            };

            if should_remove {
                let _ = fs::remove_dir_all(&path);
            }
        }
    }

    Ok(())
}
