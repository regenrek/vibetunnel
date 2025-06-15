mod protocol;
mod tty_spawn;
mod utils;

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::{env, fs};

use anyhow::anyhow;
use argument_parser::Parser;
use serde_json;
use uuid::Uuid;

use tty_spawn::{create_session_info, TtySpawn};

use crate::protocol::SessionInfo;

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

            if session_json_path.exists() {
                let session_data = if let Ok(content) = fs::read_to_string(&session_json_path) {
                    if let Ok(session_info) = serde_json::from_str::<SessionInfo>(&content) {
                        serde_json::json!({
                            "cmdline": session_info.cmdline,
                            "name": session_info.name,
                            "cwd": session_info.cwd,
                            "pid": session_info.pid,
                            "status": session_info.status,
                            "exit_code": session_info.exit_code,
                            "started_at": session_info.started_at,
                            "stream-out": stream_out_path.canonicalize().unwrap_or(stream_out_path.clone()).to_string_lossy(),
                            "stdin": stdin_path.canonicalize().unwrap_or(stdin_path.clone()).to_string_lossy()
                        })
                    } else {
                        // Fallback to old behavior if JSON parsing fails
                        let status = if stream_out_path.exists() && stdin_path.exists() {
                            "running"
                        } else {
                            "stopped"
                        };
                        serde_json::json!({
                            "status": status,
                            "stream-out": stream_out_path.canonicalize().unwrap_or(stream_out_path.clone()).to_string_lossy(),
                            "stdin": stdin_path.canonicalize().unwrap_or(stdin_path.clone()).to_string_lossy()
                        })
                    }
                } else {
                    // Fallback to old behavior if file reading fails
                    let status = if stream_out_path.exists() && stdin_path.exists() {
                        "running"
                    } else {
                        "stopped"
                    };
                    serde_json::json!({
                        "status": status,
                        "stream-out": stream_out_path.canonicalize().unwrap_or(stream_out_path.clone()).to_string_lossy(),
                        "stdin": stdin_path.canonicalize().unwrap_or(stdin_path.clone()).to_string_lossy()
                    })
                };

                sessions.insert(session_id.to_string(), session_data);
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

    let mut file = OpenOptions::new()
        .write(true)
        .append(true)
        .open(&stdin_path)?;
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

    let mut file = OpenOptions::new()
        .write(true)
        .append(true)
        .open(&stdin_path)?;
    file.write_all(text.as_bytes())?;
    file.flush()?;

    Ok(())
}

fn is_pid_alive(pid: u32) -> bool {
    use std::process::Command;

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

        if path.is_dir() {
            if let Some(_session_id) = path.file_name().and_then(|n| n.to_str()) {
                let session_json_path = path.join("session.json");

                if session_json_path.exists() {
                    let should_remove = if let Ok(content) = fs::read_to_string(&session_json_path)
                    {
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
        }
    }

    Ok(())
}

fn main() -> Result<(), anyhow::Error> {
    let mut parser = Parser::from_env();

    let mut control_path = PathBuf::from("./tty-fwd-control");
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
    let session_path = control_path.join(&session_id.to_string());
    fs::create_dir_all(&session_path)?;

    // Get executable name for session name
    let executable_name = cmdline[0]
        .to_string_lossy()
        .split('/')
        .last()
        .unwrap_or("unknown")
        .to_string();

    // Get current working directory
    let current_dir = env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let session_info_path = session_path.join("session.json");
    create_session_info(
        &session_info_path,
        cmdline
            .iter()
            .map(|s| s.to_string_lossy().to_string())
            .collect(),
        session_name.unwrap_or(executable_name),
        current_dir,
    )?;

    // Set up stream-out and stdin paths
    let stream_out_path = session_path.join("stream-out");
    let stdin_path = session_path.join("stdin");

    // Create and configure TtySpawn
    let mut tty_spawn = TtySpawn::new_cmdline(cmdline.iter().map(|s| s.as_os_str()));
    tty_spawn
        .stdout_path(&stream_out_path, true)?
        .stdin_path(&stdin_path)?
        .session_json_path(&session_info_path);

    // Spawn the process
    let exit_code = tty_spawn.spawn()?;
    std::process::exit(exit_code);
}
