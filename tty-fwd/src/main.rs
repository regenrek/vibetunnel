mod heuristics;
mod protocol;
mod server;
mod sessions;
mod tty_spawn;
mod utils;

use std::env;
use std::ffi::OsString;
use std::path::Path;

use anyhow::anyhow;
use argument_parser::Parser;

fn main() -> Result<(), anyhow::Error> {
    let mut parser = Parser::from_env();

    let mut control_path = env::home_dir()
        .ok_or_else(|| anyhow!("Unable to determine home directory"))?
        .join(".vibetunnel/control");
    let mut session_name = None::<String>;
    let mut session_id = None::<String>;
    let mut send_key = None::<String>;
    let mut send_text = None::<String>;
    let mut signal = None::<i32>;
    let mut stop = false;
    let mut kill = false;
    let mut cleanup = false;
    let mut serve_address = None::<String>;
    let mut cmdline = Vec::<OsString>::new();

    while let Some(param) = parser.param()? {
        match param {
            p if p.is_long("control-path") => {
                control_path = parser.value()?;
            }
            p if p.is_long("list-sessions") => {
                let control_path: &Path = &control_path;
                let sessions = sessions::list_sessions(control_path)?;
                println!("{}", serde_json::to_string(&sessions)?);
                return Ok(());
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
            p if p.is_long("signal") => {
                let signal_str: String = parser.value()?;
                signal = Some(
                    signal_str
                        .parse()
                        .map_err(|_| anyhow!("Invalid signal number: {}", signal_str))?,
                );
            }
            p if p.is_long("stop") => {
                stop = true;
            }
            p if p.is_long("kill") => {
                kill = true;
            }
            p if p.is_long("cleanup") => {
                cleanup = true;
            }
            p if p.is_long("serve") => {
                let addr: String = parser.value()?;
                serve_address = Some(if addr.contains(':') {
                    addr
                } else {
                    format!("127.0.0.1:{}", addr)
                });
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
                println!("                          Keys: arrow_up, arrow_down, arrow_left, arrow_right, escape, enter, ctrl_enter, shift_enter");
                println!("  --send-text <text>      Send text input to session");
                println!("  --signal <number>       Send signal number to session PID");
                println!(
                    "  --stop                  Send SIGTERM to session (equivalent to --signal 15)"
                );
                println!(
                    "  --kill                  Send SIGKILL to session (equivalent to --signal 9)"
                );
                println!("  --cleanup               Remove exited sessions (all if no --session specified)");
                println!("  --serve <addr>          Start HTTP server (hostname:port or just port for 127.0.0.1)");
                println!("  --help                  Show this help message");
                return Ok(());
            }
            _ => return Err(parser.unexpected().into()),
        }
    }

    // Handle send-key command
    if let Some(key) = send_key {
        if let Some(sid) = &session_id {
            return sessions::send_key_to_session(&control_path, sid, &key);
        } else {
            return Err(anyhow!("--send-key requires --session <session_id>"));
        }
    }

    // Handle send-text command
    if let Some(text) = send_text {
        if let Some(sid) = &session_id {
            return sessions::send_text_to_session(&control_path, sid, &text);
        } else {
            return Err(anyhow!("--send-text requires --session <session_id>"));
        }
    }

    // Handle signal command
    if let Some(sig) = signal {
        if let Some(sid) = &session_id {
            return sessions::send_signal_to_session(&control_path, sid, sig);
        } else {
            return Err(anyhow!("--signal requires --session <session_id>"));
        }
    }

    // Handle stop command (SIGTERM)
    if stop {
        if let Some(sid) = &session_id {
            return sessions::send_signal_to_session(&control_path, sid, 15);
        } else {
            return Err(anyhow!("--stop requires --session <session_id>"));
        }
    }

    // Handle kill command (SIGKILL)
    if kill {
        if let Some(sid) = &session_id {
            return sessions::send_signal_to_session(&control_path, sid, 9);
        } else {
            return Err(anyhow!("--kill requires --session <session_id>"));
        }
    }

    // Handle cleanup command
    if cleanup {
        return sessions::cleanup_sessions(&control_path, session_id.as_deref());
    }

    // Handle serve command
    if let Some(addr) = serve_address {
        return crate::server::start_server(&addr, control_path);
    }

    let exit_code = sessions::spawn_command(control_path, session_name, cmdline)?;
    std::process::exit(exit_code);
}
