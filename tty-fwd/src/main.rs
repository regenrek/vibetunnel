mod protocol;
mod tty_spawn;

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::{env, fs};

use anyhow::anyhow;
use argument_parser::Parser;
use serde_json;
use uuid::Uuid;

use tty_spawn::TtySpawn;

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
                let status = if stream_out_path.exists() && stdin_path.exists() {
                    "running"
                } else {
                    "stopped"
                };

                let session_data = serde_json::json!({
                    "status": status,
                    "stream-out": stream_out_path.to_string_lossy(),
                    "stdin": stdin_path.to_string_lossy()
                });

                sessions.insert(session_id.to_string(), session_data);
            }
        }
    }

    println!("{}", serde_json::to_string(&sessions)?);
    Ok(())
}

fn main() -> Result<(), anyhow::Error> {
    let mut parser = Parser::from_env();

    let mut control_path = PathBuf::from("./tty-fwd-control");
    let mut session_name = None::<String>;
    let mut cmdline = Vec::<OsString>::new();

    while let Some(param) = parser.param()? {
        match param {
            p if p.is_long("control-path") => {
                control_path = parser.value()?;
            }
            p if p.is_long("list-sessions") => {
                return list_sessions(&control_path);
            }
            p if p.is_long("session") => {
                session_name = Some(parser.value()?);
            }
            p if p.is_pos() => {
                cmdline.push(parser.value()?);
            }
            p if p.is_long("help") => {
                println!("Usage: tty-fwd [options] <command>");
                println!("Options:");
                println!("  --control-path <path>   Where the control folder is located");
                println!("  --session <name>        Names the session");
                println!("  --list-sessions         List all sessions");
                println!("  --help                  Show this help message");
                return Ok(());
            }
            _ => return Err(parser.unexpected().into()),
        }
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

    let session_info = SessionInfo {
        cmdline: cmdline
            .iter()
            .map(|s| s.to_string_lossy().to_string())
            .collect(),
        name: session_name.unwrap_or(executable_name),
        cwd: current_dir,
    };
    let session_info_path = session_path.join("session.json");
    let session_info_str = serde_json::to_string(&session_info)?;
    fs::write(session_info_path, session_info_str)?;

    // Set up stream-out and stdin paths
    let stream_out_path = session_path.join("stream-out");
    let stdin_path = session_path.join("stdin");

    // Create and configure TtySpawn
    let mut tty_spawn = TtySpawn::new_cmdline(cmdline.iter().map(|s| s.as_os_str()));
    tty_spawn
        .stdout_path(&stream_out_path, true)?
        .stdin_path(&stdin_path)?;

    // Spawn the process
    let exit_code = tty_spawn.spawn()?;
    std::process::exit(exit_code);
}
