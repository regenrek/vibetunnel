use anyhow::Result;
use serde_json::json;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use uuid::Uuid;
use std::env;
use nix::pty::{openpty, Winsize};
use nix::unistd::{fork, ForkResult, dup2, setsid, close};
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::ffi::CString;

/// Spawn a terminal session with PTY fallback
pub fn spawn_terminal_via_socket(
    command: &[String],
    working_dir: Option<&str>,
) -> Result<String> {
    // Try socket first
    match spawn_via_socket_impl(command, working_dir) {
        Ok(session_id) => Ok(session_id),
        Err(socket_err) => {
            eprintln!("Socket spawn failed ({}), falling back to PTY", socket_err);
            spawn_via_pty(command, working_dir)
        }
    }
}

/// Spawn a terminal session by communicating with VibeTunnel via Unix socket
fn spawn_via_socket_impl(
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

/// Spawn a terminal session using PTY directly (fallback)
fn spawn_via_pty(
    command: &[String],
    working_dir: Option<&str>,
) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();
    
    eprintln!("PTY: spawn_via_pty called with command: {:?}, working_dir: {:?}", command, working_dir);
    
    // Create PTY
    let pty_result = openpty(
        &Winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        },
        None,
    )?;
    
    // Keep the OwnedFd objects alive to prevent auto-close
    let master_owned = pty_result.master;
    let slave_owned = pty_result.slave;
    let master_fd = master_owned.as_raw_fd();
    let slave_fd = slave_owned.as_raw_fd();
    
    // Duplicate the master fd for the background thread to avoid ownership issues
    let master_fd_dup = unsafe { libc::dup(master_fd) };
    if master_fd_dup == -1 {
        return Err(anyhow::anyhow!("Failed to duplicate master fd: {}", std::io::Error::last_os_error()));
    }
    
    // Fork process
    match unsafe { fork() }? {
        ForkResult::Parent { .. } => {
            // Parent process - close slave fd
            close(slave_fd)?;
            
            // Prevent the OwnedFd from closing the master when it goes out of scope
            std::mem::forget(master_owned);
            std::mem::forget(slave_owned);
            
            // Create session.json file immediately before returning (not in background thread)
            let control_dir = env::var("TTY_FWD_CONTROL_DIR")
                .unwrap_or_else(|_| format!("{}/.vibetunnel/control", env::var("HOME").unwrap_or_default()));
            
            let session_dir = format!("{}/{}", control_dir, session_id);
            std::fs::create_dir_all(&session_dir)?;
            
            let expanded_working_dir = if let Some(dir) = working_dir {
                if dir == "~/" || dir == "~" {
                    std::env::var("HOME").unwrap_or_else(|_| "/".to_string())
                } else if dir.starts_with("~/") {
                    format!("{}/{}", std::env::var("HOME").unwrap_or_else(|_| "/".to_string()), &dir[2..])
                } else {
                    dir.to_string()
                }
            } else {
                std::env::var("HOME").unwrap_or_else(|_| "/".to_string())
            };
            
            let cmdline = if command.is_empty() {
                vec!["zsh".to_string()]
            } else {
                command.to_vec()
            };
            
            let session_name = if command.is_empty() {
                "Terminal".to_string()
            } else {
                format!("{} (PTY)", command[0])
            };
            
            let session_info = json!({
                "cmdline": cmdline,
                "name": session_name,
                "cwd": expanded_working_dir,
                "status": "running",
                "started_at": jiff::Timestamp::now(),
                "term": "xterm-256color"
            });
            std::fs::write(format!("{}/session.json", session_dir), serde_json::to_string_pretty(&session_info)?)?;
            
            // Start a background thread to handle PTY I/O
            let session_id_clone = session_id.clone();
            let command_clone = command.to_vec();
            let working_dir_clone = working_dir.map(|s| s.to_string());
            std::thread::spawn(move || {
                if let Err(e) = handle_pty_session(master_fd_dup, &session_id_clone, &command_clone, working_dir_clone.as_deref()) {
                    eprintln!("PTY session error: {}", e);
                }
                // Clean up the duplicated fd when done
                unsafe { libc::close(master_fd_dup); }
            });
            
            Ok(session_id)
        }
        ForkResult::Child => {
            // Child process - set up PTY and exec command
            eprintln!("PTY Child: Starting child process");
            
            if let Err(e) = close(master_fd) {
                eprintln!("PTY Child: Failed to close master_fd: {}", e);
                std::process::exit(1);
            }
            eprintln!("PTY Child: Closed master_fd");
            
            // Create new session
            if let Err(e) = setsid() {
                eprintln!("PTY Child: Failed to setsid: {}", e);
                std::process::exit(1);
            }
            eprintln!("PTY Child: Created new session");
            
            // Set up stdin/stdout/stderr to use the slave PTY
            if let Err(e) = dup2(slave_fd, 0) {
                eprintln!("PTY Child: Failed to dup2 stdin: {}", e);
                std::process::exit(1);
            }
            if let Err(e) = dup2(slave_fd, 1) {
                eprintln!("PTY Child: Failed to dup2 stdout: {}", e);
                std::process::exit(1);
            }
            if let Err(e) = dup2(slave_fd, 2) {
                eprintln!("PTY Child: Failed to dup2 stderr: {}", e);
                std::process::exit(1);
            }
            if let Err(e) = close(slave_fd) {
                eprintln!("PTY Child: Failed to close slave_fd: {}", e);
                std::process::exit(1);
            }
            eprintln!("PTY Child: Set up file descriptors");
            
            // Change working directory if specified
            if let Some(dir) = working_dir {
                let expanded_dir = if dir == "~/" || dir == "~" {
                    std::env::var("HOME").unwrap_or_else(|_| "/".to_string())
                } else if dir.starts_with("~/") {
                    format!("{}/{}", std::env::var("HOME").unwrap_or_else(|_| "/".to_string()), &dir[2..])
                } else {
                    dir.to_string()
                };
                
                eprintln!("PTY Child: Changing directory from '{}' to '{}'", dir, expanded_dir);
                if let Err(e) = std::env::set_current_dir(&expanded_dir) {
                    eprintln!("PTY Child: Failed to change directory to {}: {}", expanded_dir, e);
                    std::process::exit(1);
                }
                eprintln!("PTY Child: Changed directory to {}", expanded_dir);
            }
            
            // Execute the command
            let program = if command.is_empty() {
                // Default to shell if no command specified - try common shell paths
                if std::path::Path::new("/bin/bash").exists() {
                    "/bin/bash"
                } else if std::path::Path::new("/bin/sh").exists() {
                    "/bin/sh"
                } else if std::path::Path::new("/usr/bin/bash").exists() {
                    "/usr/bin/bash"
                } else {
                    "sh" // fallback to PATH lookup
                }
            } else {
                command.first().unwrap()
            };
            
            eprintln!("PTY: Executing command: {:?} with args: {:?}", program, command);
            
            let args: Vec<CString> = if command.is_empty() {
                vec![CString::new(program)?]
            } else {
                command.iter()
                    .map(|s| CString::new(s.as_str()))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| anyhow::anyhow!("Invalid command argument: {}", e))?
            };
            
            eprintln!("PTY: About to execvp with program={:?}, args={:?}", program, args);
            
            // Use execvp to execute the command
            match nix::unistd::execvp(&CString::new(program)?, &args) {
                Ok(_) => {
                    eprintln!("PTY: execvp succeeded (this should never print)");
                }
                Err(e) => {
                    eprintln!("PTY: execvp failed: {}", e);
                    std::process::exit(127); // Standard exit code for command not found
                }
            }
            
            // This should never be reached
            std::process::exit(1);
        }
    }
}

/// Handle PTY session I/O - read from PTY and write to session file
fn handle_pty_session(master_fd: RawFd, session_id: &str, command: &[String], working_dir: Option<&str>) -> Result<()> {
    use std::fs::OpenOptions;
    use std::io::BufWriter;
    
    // Get session control directory  
    let control_dir = env::var("TTY_FWD_CONTROL_DIR")
        .unwrap_or_else(|_| format!("{}/.vibetunnel/control", env::var("HOME").unwrap_or_default()));
    
    let session_dir = format!("{}/{}", control_dir, session_id);
    // Session directory and session.json are already created by parent process
    
    // Create stdin FIFO
    let stdin_path = format!("{}/stdin", session_dir);
    // Use libc directly to create FIFO to avoid nix version conflicts
    let stdin_path_c = CString::new(stdin_path.clone())?;
    unsafe {
        libc::mkfifo(stdin_path_c.as_ptr(), 0o666);
    }
    
    // Create output file
    let output_path = format!("{}/stream-out", session_dir);
    let output_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&output_path)?;
    
    let mut writer = BufWriter::new(output_file);
    
    // Start stdin handler thread
    let master_fd_dup2 = unsafe { libc::dup(master_fd) };
    if master_fd_dup2 != -1 {
        let stdin_path_clone = stdin_path.clone();
        std::thread::spawn(move || {
            if let Err(e) = handle_stdin_to_pty(master_fd_dup2, &stdin_path_clone) {
                eprintln!("Stdin handler error: {}", e);
            }
            // Clean up the duplicated fd when done
            unsafe { libc::close(master_fd_dup2); }
        });
    }
    
    // Write initial header
    let header = json!({
        "version": 2,
        "width": 80,
        "height": 24,
        "timestamp": jiff::Timestamp::now().as_second()
    });
    writeln!(writer, "{}", header)?;
    
    // Read from PTY and write to file
    let mut buffer = [0u8; 8192];
    
    loop {
        // Use libc::read directly to avoid File ownership issues
        let bytes_read = unsafe {
            libc::read(master_fd, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len())
        };
        
        match bytes_read {
            -1 => {
                let errno = std::io::Error::last_os_error();
                eprintln!("Error reading from PTY: {}", errno);
                break;
            }
            0 => {
                eprintln!("PTY closed (EOF)");
                break; // EOF
            }
            n => {
                let data = &buffer[..n as usize];
                let event = json!([
                    0, // timestamp offset
                    "o", // output event
                    String::from_utf8_lossy(data)
                ]);
                writeln!(writer, "{}", event)?;
                writer.flush()?;
            }
        }
    }
    
    Ok(())
}

/// Handle stdin FIFO -> PTY master forwarding
fn handle_stdin_to_pty(master_fd: RawFd, stdin_path: &str) -> Result<()> {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;
    use nix::fcntl::OFlag;
    
    // Open stdin FIFO for reading (non-blocking)
    let stdin_file = OpenOptions::new()
        .read(true)
        .write(true) // Open for write too to prevent blocking
        .custom_flags(OFlag::O_NONBLOCK.bits())
        .open(stdin_path)?;
    
    let mut buffer = [0u8; 1024];
    
    loop {
        use std::io::Read;
        let mut stdin_file_ref = &stdin_file;
        match stdin_file_ref.read(&mut buffer) {
            Ok(0) => {
                // No data available, sleep briefly to avoid busy waiting
                std::thread::sleep(std::time::Duration::from_millis(10));
                continue;
            }
            Ok(n) => {
                // Write to PTY master using libc::write
                let bytes_written = unsafe {
                    libc::write(master_fd, buffer.as_ptr() as *const libc::c_void, n)
                };
                if bytes_written == -1 {
                    eprintln!("Error writing to PTY: {}", std::io::Error::last_os_error());
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // No data available, sleep briefly
                std::thread::sleep(std::time::Duration::from_millis(10));
                continue;
            }
            Err(e) => {
                eprintln!("Error reading from stdin FIFO: {}", e);
                break;
            }
        }
    }
    
    Ok(())
}