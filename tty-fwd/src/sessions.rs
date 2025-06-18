use anyhow::anyhow;
use std::collections::HashMap;
use std::ffi::OsString;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;
use std::time::Duration;
use uuid::Uuid;

use crate::protocol::{SessionEntryWithId, SessionInfo, SessionListEntry};
use crate::tty_spawn::TtySpawn;

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
                    .unwrap_or_else(|_| stream_out_path.clone())
                    .to_string_lossy()
                    .to_string();
                let stdin = stdin_path
                    .canonicalize()
                    .unwrap_or_else(|_| stdin_path.clone())
                    .to_string_lossy()
                    .to_string();
                let notification_stream = notification_stream_path
                    .canonicalize()
                    .unwrap_or_else(|_| notification_stream_path.clone())
                    .to_string_lossy()
                    .to_string();
                let mut session_info: SessionInfo = fs::read_to_string(&session_json_path)
                    .and_then(|content| serde_json::from_str(&content).map_err(Into::into))
                    .unwrap_or_default();

                // Check if the process is still alive and update status if needed
                if session_info.status == "running" {
                    if let Some(pid) = session_info.pid {
                        if !is_pid_alive(pid) {
                            session_info.status = "exited".to_string();
                        }
                    }
                }

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

pub fn find_current_session(
    control_path: &Path,
) -> Result<Option<SessionEntryWithId>, anyhow::Error> {
    let sessions = list_sessions(control_path)?;

    // Get current process PID
    let current_pid = std::process::id();

    // Check each session to see if current process or any parent is part of it
    for (session_id, session_entry) in sessions {
        if let Some(session_pid) = session_entry.session_info.pid {
            // Check if this session PID is in our process ancestry
            if is_process_descendant_of(current_pid, session_pid) {
                return Ok(Some(SessionEntryWithId {
                    session_id,
                    entry: session_entry,
                }));
            }
        }
    }

    Ok(None)
}

fn is_process_descendant_of(mut current_pid: u32, target_pid: u32) -> bool {
    // Check if current process is the target or a descendant of target
    while current_pid > 1 {
        if current_pid == target_pid {
            return true;
        }

        // Get parent PID
        match get_parent_pid(current_pid) {
            Some(parent_pid) => current_pid = parent_pid,
            None => break,
        }
    }

    false
}

fn get_parent_pid(pid: u32) -> Option<u32> {
    // Use ps command to get parent PID
    let output = Command::new("ps")
        .arg("-p")
        .arg(pid.to_string())
        .arg("-o")
        .arg("ppid=")
        .output()
        .ok()?;

    if output.status.success() {
        let ppid_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        ppid_str.parse::<u32>().ok()
    } else {
        None
    }
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
        "enter" | "ctrl_enter" => b"\r", // Just CR like normal enter for now - let's test this first
        "shift_enter" => b"\x1b\x0d",    // ESC + Enter - simpler approach
        _ => return Err(anyhow!("Unknown key: {}", key)),
    };

    // Use a timeout-protected write operation that also checks for readers
    write_to_pipe_with_timeout(&stdin_path, key_bytes, Duration::from_secs(5))?;

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

    // Use a timeout-protected write operation that also checks for readers
    write_to_pipe_with_timeout(&stdin_path, text.as_bytes(), Duration::from_secs(5))?;

    Ok(())
}

fn write_to_pipe_with_timeout(
    pipe_path: &Path,
    data: &[u8],
    timeout: Duration,
) -> Result<(), anyhow::Error> {
    // Open the pipe in non-blocking mode first to check if it has readers
    let file = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(pipe_path)?;

    let fd = file.as_raw_fd();

    // Use poll to check if the pipe is writable with timeout
    let mut pollfd = libc::pollfd {
        fd,
        events: libc::POLLOUT,
        revents: 0,
    };

    let timeout_ms = timeout.as_millis() as libc::c_int;

    let poll_result = unsafe { libc::poll(&mut pollfd, 1, timeout_ms) };

    match poll_result {
        -1 => {
            let errno = std::io::Error::last_os_error();
            return Err(anyhow!("Poll failed: {}", errno));
        }
        0 => {
            return Err(anyhow!("Write operation timed out after {:?}", timeout));
        }
        _ => {
            // Check poll results
            if pollfd.revents & libc::POLLERR != 0 {
                return Err(anyhow!("Pipe error detected"));
            }
            if pollfd.revents & libc::POLLHUP != 0 {
                return Err(anyhow!("Pipe has no readers (POLLHUP)"));
            }
            if pollfd.revents & libc::POLLNVAL != 0 {
                return Err(anyhow!("Invalid pipe file descriptor"));
            }
            if pollfd.revents & libc::POLLOUT == 0 {
                return Err(anyhow!("Pipe not ready for writing"));
            }
        }
    }

    // At this point, the pipe is ready for writing
    // Re-open in blocking mode and write the data
    drop(file); // Close the non-blocking file descriptor

    let mut blocking_file = OpenOptions::new().append(true).open(pipe_path)?;

    blocking_file.write_all(data)?;
    blocking_file.flush()?;

    Ok(())
}

pub fn is_pid_alive(pid: u32) -> bool {
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

pub fn spawn_command(
    control_path: std::path::PathBuf,
    session_name: Option<String>,
    session_id: Option<String>,
    cmdline: Vec<OsString>,
) -> Result<i32, anyhow::Error> {
    if cmdline.is_empty() {
        return Err(anyhow!("No command provided"));
    }

    let session_id = session_id.unwrap_or_else(|| Uuid::new_v4().to_string());
    let session_path = control_path.join(session_id);
    fs::create_dir_all(&session_path)?;
    let session_info_path = session_path.join("session.json");
    let stream_out_path = session_path.join("stream-out");
    let stdin_path = session_path.join("stdin");
    let notification_stream_path = session_path.join("notification-stream");
    let mut tty_spawn = TtySpawn::new_cmdline(cmdline.iter().map(std::ffi::OsString::as_os_str));
    tty_spawn
        .stdout_path(&stream_out_path, true)?
        .stdin_path(&stdin_path)?
        .session_json_path(&session_info_path);
    if let Some(name) = session_name {
        tty_spawn.session_name(name);
    }
    tty_spawn.notification_path(&notification_stream_path)?;
    let exit_code = tty_spawn.spawn()?;
    Ok(exit_code)
}
