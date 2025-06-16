mod heuristics;
mod protocol;
mod tty_spawn;
mod utils;

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::process::Command;
use std::{env, fs};

use anyhow::anyhow;
use argument_parser::Parser;
use uuid::Uuid;

use crate::protocol::{SessionInfo, SessionListEntry};
use crate::tty_spawn::TtySpawn;

fn list_sessions(control_path: &Path) -> Result<(), anyhow::Error> {
    let mut sessions = HashMap::new();

    if !control_path.exists() {
        println!("{}", serde_json::to_string(&sessions)?);
        return Ok(());
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

                let session_entry = SessionListEntry {
                    session_info,
                    stream_out,
                    stdin,
                    notification_stream,
                };

                sessions.insert(session_id.to_string(), serde_json::to_value(session_entry)?);
            }
        }
    }

    println!("{}", serde_json::to_string(&sessions)?);
    Ok(())
}

fn send_key_to_session(
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
        _ => return Err(anyhow!("Unknown key: {}", key)),
    };

    let mut file = OpenOptions::new().append(true).open(&stdin_path)?;
    file.write_all(key_bytes)?;
    file.flush()?;

    Ok(())
}

fn send_text_to_session(
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

fn cleanup_sessions(
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

fn main() -> Result<(), anyhow::Error> {
    let mut parser = Parser::from_env();

    let mut control_path = env::home_dir()
        .ok_or_else(|| anyhow!("Unable to determine home directory"))?
        .join(".vibetunnel/control");
    let mut session_name = None::<String>;
    let mut session_id = None::<String>;
    let mut send_key = None::<String>;
    let mut send_text = None::<String>;
    let mut cleanup = false;
    let mut cmdline = Vec::<OsString>::new();

    while let Some(param) = parser.param()? {
        match param {
            p if p.is_long("control-path") => {
                control_path = parser.value()?;
            }
            p if p.is_long("list-sessions") => {
                return list_sessions(&control_path);
            }
            p if p.is_long("session-name") => {
                session_name = Some(parser.value()?);
            }
            p if p.is_long("session") => {
                session_id = Some(parser.value()?);
            }
            p if p.is_long("send-key") => {
                send_key = Some(parser.value()?);
            }
            p if p.is_long("send-text") => {
                send_text = Some(parser.value()?);
            }
            p if p.is_long("cleanup") => {
                cleanup = true;
            }
            p if p.is_pos() => {
                cmdline.push(parser.value()?);
            }
            p if p.is_long("help") => {
                println!("Usage: tty-fwd [options] -- <command>");
                println!("Options:");
                println!("  --control-path <path>   Where the control folder is located");
                println!("  --session-name <name>   Names the session when creating");
                println!("  --list-sessions         List all sessions");
                println!("  --session <I>           Operate on this session");
                println!("  --send-key <key>        Send key input to session");
                println!("                          Keys: arrow_up, arrow_down, arrow_left, arrow_right, escape, enter");
                println!("  --send-text <text>      Send text input to session");
                println!("  --cleanup               Remove exited sessions (all if no --session specified)");
                println!("  --help                  Show this help message");
                return Ok(());
            }
            _ => return Err(parser.unexpected().into()),
        }
    }

    // Handle send-key command
    if let Some(key) = send_key {
        if let Some(sid) = &session_id {
            return send_key_to_session(&control_path, sid, &key);
        } else {
            return Err(anyhow!("--send-key requires --session <session_id>"));
        }
    }

    // Handle send-text command
    if let Some(text) = send_text {
        if let Some(sid) = &session_id {
            return send_text_to_session(&control_path, sid, &text);
        } else {
            return Err(anyhow!("--send-text requires --session <session_id>"));
        }
    }

    // Handle cleanup command
    if cleanup {
        return cleanup_sessions(&control_path, session_id.as_deref());
    }

    if cmdline.is_empty() {
        return Err(anyhow!("No command provided"));
    }

    let session_id = Uuid::new_v4();
    let session_path = control_path.join(session_id.to_string());
    fs::create_dir_all(&session_path)?;

    let session_info_path = session_path.join("session.json");

    // Set up stream-out and stdin paths
    let stream_out_path = session_path.join("stream-out");
    let stdin_path = session_path.join("stdin");
    let notification_stream_path = session_path.join("notification-stream");

    // Create and configure TtySpawn
    let mut tty_spawn = TtySpawn::new_cmdline(cmdline.iter().map(|s| s.as_os_str()));
    tty_spawn
        .stdout_path(&stream_out_path, true)?
        .stdin_path(&stdin_path)?
        .session_json_path(&session_info_path);

    if let Some(name) = session_name {
        tty_spawn.session_name(name);
    }

    // Always enable notification stream
    tty_spawn.notification_path(&notification_stream_path)?;

    // Spawn the process
    let exit_code = tty_spawn.spawn()?;
    std::process::exit(exit_code);
}
