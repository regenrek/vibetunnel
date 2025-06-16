use std::env;
use std::ffi::{CString, OsStr, OsString};
use std::fs::File;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, IntoRawFd, OwnedFd};
use std::os::unix::prelude::{AsRawFd, OpenOptionsExt, OsStrExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tempfile::NamedTempFile;

use crate::heuristics::InputDetectionHeuristics;
use crate::protocol::{
    AsciinemaEvent, AsciinemaEventType, AsciinemaHeader, NotificationEvent, NotificationWriter,
    SessionInfo, StreamWriter,
};
use jiff::Timestamp;

use nix::errno::Errno;
use nix::libc;
use nix::libc::{login_tty, O_NONBLOCK, TIOCGWINSZ, TIOCSWINSZ, VEOF};
use nix::pty::{openpty, Winsize};
use nix::sys::select::{select, FdSet};
use nix::sys::signal::{killpg, Signal};
use nix::sys::stat::Mode;
use nix::sys::termios::{cfmakeraw, tcgetattr, tcsetattr, LocalFlags, SetArg, Termios};
use nix::sys::time::TimeVal;
use nix::sys::wait::{waitpid, WaitStatus};
use nix::unistd::{
    close, dup2, execvp, fork, mkfifo, read, setsid, tcgetpgrp, write, ForkResult, Pid,
};
use signal_hook::consts::SIGWINCH;

/// Lets you spawn processes with a TTY connected.
pub struct TtySpawn {
    options: Option<SpawnOptions>,
}

impl TtySpawn {
    /// Alternative way to construct a [`TtySpawn`].
    ///
    /// Takes an iterator of command and arguments.  If the iterator is empty this
    /// panicks.
    ///
    /// # Panicks
    ///
    /// If the iterator is empty, this panics.
    pub fn new_cmdline<S: AsRef<OsStr>, I: Iterator<Item = S>>(mut cmdline: I) -> Self {
        let mut command = vec![cmdline
            .next()
            .expect("empty cmdline")
            .as_ref()
            .to_os_string()];
        command.extend(cmdline.map(|arg| arg.as_ref().to_os_string()));

        TtySpawn {
            options: Some(SpawnOptions {
                command,
                stdin_file: None,
                stdout_file: None,
                notification_writer: None,
                session_json_path: None,
                session_name: None,
                detached: false,
                term: "xterm".to_string(),
            }),
        }
    }

    /// Sets a path as input file for stdin.
    pub fn stdin_path<P: AsRef<Path>>(&mut self, path: P) -> Result<&mut Self, io::Error> {
        let path = path.as_ref();
        mkfifo_atomic(path)?;
        // for the justification for write(true) see the explanation on
        // stdin_file - we need to open for both read and write to prevent
        // polling primitives from reporting ready when no data is available.
        let file = File::options()
            .read(true)
            .write(true)
            .custom_flags(O_NONBLOCK)
            .open(path)?;
        self.options_mut().stdin_file = Some(file);
        Ok(self)
    }

    /// Sets a path as output file for stdout.
    ///
    /// If the `truncate` flag is set to `true` the file will be truncated
    /// first, otherwise it will be appended to.
    pub fn stdout_path<P: AsRef<Path>>(
        &mut self,
        path: P,
        truncate: bool,
    ) -> Result<&mut Self, io::Error> {
        let file = if !truncate {
            File::options().append(true).create(true).open(path)?
        } else {
            File::options()
                .create(true)
                .truncate(true)
                .write(true)
                .open(path)?
        };

        self.options_mut().stdout_file = Some(file);
        Ok(self)
    }

    /// Sets the session JSON path for status updates.
    pub fn session_json_path<P: AsRef<Path>>(&mut self, path: P) -> &mut Self {
        self.options_mut().session_json_path = Some(path.as_ref().to_path_buf());
        self
    }

    /// Sets the session name.
    pub fn session_name<S: Into<String>>(&mut self, name: S) -> &mut Self {
        self.options_mut().session_name = Some(name.into());
        self
    }

    /// Sets the process to run in detached mode (don't connect to current terminal).
    pub fn detached(&mut self, detached: bool) -> &mut Self {
        self.options_mut().detached = detached;
        self
    }

    /// Sets a path as output file for notifications.
    pub fn notification_path<P: AsRef<Path>>(&mut self, path: P) -> Result<&mut Self, io::Error> {
        let file = File::options().create(true).append(true).open(path)?;

        let notification_writer = NotificationWriter::new(file);
        self.options_mut().notification_writer = Some(notification_writer);
        Ok(self)
    }

    /// Sets the TERM environment variable for the spawned process.
    pub fn term<S: AsRef<str>>(&mut self, term: S) -> &mut Self {
        self.options_mut().term = term.as_ref().to_string();
        self
    }

    /// Spawns the application in the TTY.
    pub fn spawn(&mut self) -> Result<i32, io::Error> {
        Ok(spawn(
            self.options.take().expect("builder only works once"),
        )?)
    }

    fn options_mut(&mut self) -> &mut SpawnOptions {
        self.options.as_mut().expect("builder only works once")
    }
}

struct SpawnOptions {
    command: Vec<OsString>,
    stdin_file: Option<File>,
    stdout_file: Option<File>,
    notification_writer: Option<NotificationWriter>,
    session_json_path: Option<PathBuf>,
    session_name: Option<String>,
    detached: bool,
    term: String,
}

/// Creates a new session JSON file with the provided information
pub fn create_session_info(
    session_json_path: &Path,
    cmdline: Vec<String>,
    name: String,
    cwd: String,
    term: String,
) -> Result<(), io::Error> {
    let session_info = SessionInfo {
        cmdline,
        name,
        cwd,
        pid: None,
        status: "starting".to_string(),
        exit_code: None,
        started_at: Some(Timestamp::now()),
        waiting: false,
        term,
    };

    let session_info_str = serde_json::to_string(&session_info)?;

    // Write to temporary file first, then move to final location
    let temp_file =
        NamedTempFile::new_in(session_json_path.parent().unwrap_or_else(|| Path::new(".")))?;
    std::fs::write(temp_file.path(), session_info_str)?;
    temp_file.persist(session_json_path)?;

    Ok(())
}

/// Updates the session status in the JSON file
fn update_session_status(
    session_json_path: &Path,
    pid: Option<u32>,
    status: &str,
    exit_code: Option<i32>,
) -> Result<(), io::Error> {
    if let Ok(content) = std::fs::read_to_string(session_json_path) {
        if let Ok(mut session_info) = serde_json::from_str::<SessionInfo>(&content) {
            if let Some(pid) = pid {
                session_info.pid = Some(pid);
            }
            session_info.status = status.to_string();
            if let Some(code) = exit_code {
                session_info.exit_code = Some(code);
            }
            let updated_content = serde_json::to_string(&session_info)?;

            // Write to temporary file first, then move to final location
            let temp_file = NamedTempFile::new_in(
                session_json_path.parent().unwrap_or_else(|| Path::new(".")),
            )?;
            std::fs::write(temp_file.path(), updated_content)?;
            temp_file.persist(session_json_path)?;
        }
    }
    Ok(())
}

/// Updates the waiting status in the session JSON file
fn update_session_waiting(session_json_path: &Path, waiting: bool) -> Result<(), io::Error> {
    if let Ok(content) = std::fs::read_to_string(session_json_path) {
        if let Ok(mut session_info) = serde_json::from_str::<SessionInfo>(&content) {
            session_info.waiting = waiting;
            let updated_content = serde_json::to_string(&session_info)?;

            // Write to temporary file first, then move to final location
            let temp_file = NamedTempFile::new_in(
                session_json_path.parent().unwrap_or_else(|| Path::new(".")),
            )?;
            std::fs::write(temp_file.path(), updated_content)?;
            temp_file.persist(session_json_path)?;
        }
    }
    Ok(())
}

/// Spawns a process in a PTY in a manor similar to `script`
/// but with separate stdout/stderr.
///
/// It leaves stdin/stdout/stderr connected but also writes events into the
/// optional `out` log file.  Additionally it can retrieve instructions from
/// the given control socket.
fn spawn(mut opts: SpawnOptions) -> Result<i32, Errno> {
    // Create session info at the beginning if we have a session JSON path
    if let Some(ref session_json_path) = opts.session_json_path {
        // Get executable name for session name
        let executable_name = opts.command[0]
            .to_string_lossy()
            .split('/')
            .next_back()
            .unwrap_or("unknown")
            .to_string();

        // Get current working directory
        let current_dir = env::current_dir()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| "unknown".to_string());

        let cmdline: Vec<String> = opts
            .command
            .iter()
            .map(|s| s.to_string_lossy().to_string())
            .collect();

        let session_name = opts.session_name.clone().unwrap_or(executable_name);

        create_session_info(
            session_json_path,
            cmdline.clone(),
            session_name.clone(),
            current_dir.clone(),
            opts.term.clone(),
        )
        .map_err(|e| Errno::from_raw(e.raw_os_error().unwrap_or(libc::EIO)))?;

        // Send session started notification
        if let Some(ref mut notification_writer) = opts.notification_writer {
            let notification = NotificationEvent {
                timestamp: Timestamp::now(),
                event: "session_started".to_string(),
                data: serde_json::json!({
                    "cmdline": cmdline,
                    "name": session_name,
                    "cwd": current_dir
                }),
            };
            let _ = notification_writer.write_notification(notification);
        }
    }
    // if we can't retrieve the terminal atts we're not directly connected
    // to a pty in which case we won't do any of the terminal related
    // operations. In detached mode, we don't connect to the current terminal.
    let term_attrs = if opts.detached {
        None
    } else {
        tcgetattr(io::stdin()).ok()
    };
    let winsize = if opts.detached {
        Some(Winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        })
    } else {
        term_attrs
            .as_ref()
            .and_then(|_| get_winsize(io::stdin().as_fd()))
    };

    // Create the outer pty for stdout
    let pty = openpty(&winsize, &term_attrs)?;

    // We always use raw mode since script_mode and no_raw are always false.
    // This switches the terminal to raw mode and restores it on Drop.
    // Unfortunately due to all our shenanigans here we have no real guarantee
    // that `Drop` is called so there will be cases where the term is left in
    // raw state and requires a reset :(
    let _restore_term = term_attrs.as_ref().map(|term_attrs| {
        let mut raw_attrs = term_attrs.clone();
        cfmakeraw(&mut raw_attrs);
        raw_attrs.local_flags.remove(LocalFlags::ECHO);
        tcsetattr(io::stdin(), SetArg::TCSAFLUSH, &raw_attrs).ok();
        RestoreTerm(term_attrs.clone())
    });

    // set some flags after pty has been created.  There are cases where we
    // want to remove the ECHO flag so we don't see ^D and similar things in
    // the output.  Likewise in script mode we want to remove OPOST which will
    // otherwise convert LF to CRLF.
    // Since script_mode and no_echo are always false, we don't need to
    // modify any terminal attributes for the pty master.

    // Fork and establish the communication loop in the parent.  This unfortunately
    // has to merge stdout/stderr since the pseudo terminal only has one stream for
    // both.
    let detached = opts.detached;

    if detached {
        // Use double fork to properly daemonize the process
        match unsafe { fork()? } {
            ForkResult::Parent { child: first_child } => {
                // Wait for the first child to exit immediately
                let _ = waitpid(first_child, None)?;
                drop(pty.slave);

                // Start a monitoring thread that doesn't block the parent
                // We'll monitor the PTY master for activity and session files
                let master_fd = pty.master;
                let session_json_path = opts.session_json_path.clone();
                let notification_writer = opts.notification_writer;
                let stdin_file = opts.stdin_file;

                // Create StreamWriter for detached session if we have an output file
                let stream_writer = if let Some(stdout_file) = opts.stdout_file {
                    // Collect relevant environment variables
                    let mut env_vars = std::collections::HashMap::new();
                    env_vars.insert("TERM".to_string(), opts.term.clone());

                    // Include other important terminal-related environment variables if they exist
                    for var in ["SHELL", "LANG", "LC_ALL", "PATH", "USER", "HOME"] {
                        if let Ok(value) = std::env::var(var) {
                            env_vars.insert(var.to_string(), value);
                        }
                    }

                    let header = AsciinemaHeader {
                        version: 2,
                        width: winsize.as_ref().map_or(80, |x| x.ws_col as u32),
                        height: winsize.as_ref().map_or(24, |x| x.ws_row as u32),
                        timestamp: Some(
                            std::time::SystemTime::now()
                                .duration_since(std::time::SystemTime::UNIX_EPOCH)
                                .unwrap_or_default()
                                .as_secs(),
                        ),
                        duration: None,
                        command: Some(
                            opts.command
                                .iter()
                                .map(|s| s.to_string_lossy().to_string())
                                .collect::<Vec<_>>()
                                .join(" "),
                        ),
                        title: opts.session_name.clone(),
                        env: Some(env_vars),
                        theme: None,
                    };

                    StreamWriter::new(stdout_file, header).ok()
                } else {
                    None
                };

                std::thread::spawn(move || {
                    // Monitor the session by watching the PTY and session files
                    let _ = monitor_detached_session(
                        master_fd,
                        session_json_path.as_deref(),
                        notification_writer,
                        stream_writer,
                        stdin_file,
                    );
                });

                return Ok(0);
            }
            ForkResult::Child => {
                // First child - fork again and exit immediately
                match unsafe { fork()? } {
                    ForkResult::Parent { .. } => {
                        // First child exits immediately to orphan the grandchild
                        std::process::exit(0);
                    }
                    ForkResult::Child => {
                        // Grandchild - this becomes the daemon
                        // Continue to the child process setup below
                    }
                }
            }
        }
    } else if let ForkResult::Parent { child } = unsafe { fork()? } {
        drop(pty.slave);
        let stderr_pty = None; // Always None since script_mode is always false

        // Update session status to running with PID
        if let Some(ref session_json_path) = opts.session_json_path {
            let _ = update_session_status(
                session_json_path,
                Some(child.as_raw() as u32),
                "running",
                None,
            );
        }

        // Create StreamWriter if we have an output file
        let mut stream_writer = if let Some(stdout_file) = opts.stdout_file.take() {
            // Collect relevant environment variables
            let mut env_vars = std::collections::HashMap::new();
            env_vars.insert("TERM".to_string(), opts.term.clone());

            // Include other important terminal-related environment variables if they exist
            for var in ["SHELL", "LANG", "LC_ALL", "PATH", "USER", "HOME"] {
                if let Ok(value) = std::env::var(var) {
                    env_vars.insert(var.to_string(), value);
                }
            }

            let header = AsciinemaHeader {
                version: 2,
                width: winsize.as_ref().map_or(80, |x| x.ws_col as u32),
                height: winsize.as_ref().map_or(24, |x| x.ws_row as u32),
                timestamp: Some(
                    std::time::SystemTime::now()
                        .duration_since(std::time::SystemTime::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                ),
                duration: None,
                command: Some(
                    opts.command
                        .iter()
                        .map(|s| s.to_string_lossy().to_string())
                        .collect::<Vec<_>>()
                        .join(" "),
                ),
                title: opts.session_name.clone(),
                env: Some(env_vars),
                theme: None,
            };

            Some(
                StreamWriter::new(stdout_file, header)
                    .map_err(|e| Errno::from_raw(e.raw_os_error().unwrap_or(libc::EIO)))?,
            )
        } else {
            None
        };

        let exit_code = communication_loop(
            pty.master,
            child,
            term_attrs.is_some() && !opts.detached,
            stream_writer.as_mut(),
            opts.stdin_file.as_mut(),
            stderr_pty,
            true, // flush is always enabled
            opts.notification_writer.as_mut(),
            opts.session_json_path.as_deref(),
        )?;

        // Update session status to exited with exit code
        if let Some(ref session_json_path) = opts.session_json_path {
            let _ = update_session_status(session_json_path, None, "exited", Some(exit_code));
        }

        // Send session exited notification
        if let Some(ref mut notification_writer) = opts.notification_writer {
            let notification = NotificationEvent {
                timestamp: Timestamp::now(),
                event: "session_exited".to_string(),
                data: serde_json::json!({
                    "exit_code": exit_code
                }),
            };
            let _ = notification_writer.write_notification(notification);
        }

        return Ok(exit_code);
    }

    // Since no_pager and script_mode are always false, we don't set PAGER.

    // If we reach this point we're the child and we want to turn into the
    // target executable after having set up the tty with `login_tty` which
    // rebinds stdin/stdout/stderr to the pty.
    let args = opts
        .command
        .iter()
        .filter_map(|x| CString::new(x.as_bytes()).ok())
        .collect::<Vec<_>>();

    drop(pty.master);
    if detached {
        // Set TERM environment variable for the child process
        env::set_var("TERM", &opts.term);

        // In detached mode, manually set up file descriptors without login_tty
        // This prevents the child from connecting to the current terminal

        // Create a new session to detach from controlling terminal
        let _ = setsid();

        // Update session status with the actual daemon PID
        if let Some(ref session_json_path) = opts.session_json_path {
            let daemon_pid = std::process::id();
            let _ = update_session_status(session_json_path, Some(daemon_pid), "running", None);
        }

        // Redirect stdin, stdout, stderr to the pty slave
        let slave_fd = pty.slave.as_raw_fd();
        dup2(slave_fd, 0).expect("Failed to dup2 stdin");
        dup2(slave_fd, 1).expect("Failed to dup2 stdout");
        dup2(slave_fd, 2).expect("Failed to dup2 stderr");

        // Close the original slave fd if it's not one of the standard fds
        if slave_fd > 2 {
            close(slave_fd).ok();
        }
    } else {
        unsafe {
            login_tty(pty.slave.into_raw_fd());
            // No stderr redirection since script_mode is always false
        }
    }

    // Since this returns Infallible rather than ! due to limitations, we need
    // this dummy match.
    match execvp(&args[0], &args)? {}
}

#[allow(clippy::too_many_arguments)]
fn communication_loop(
    master: OwnedFd,
    child: Pid,
    is_tty: bool,
    mut stream_writer: Option<&mut StreamWriter>,
    in_file: Option<&mut File>,
    stderr: Option<OwnedFd>,
    flush: bool,
    mut notification_writer: Option<&mut NotificationWriter>,
    session_json_path: Option<&Path>,
) -> Result<i32, Errno> {
    let mut buf = [0; 4096];
    let mut read_stdin = is_tty;
    let mut done = false;
    let stdin = io::stdin();
    let mut heuristics = InputDetectionHeuristics::new();
    let mut input_notification_sent = false;
    let mut current_waiting_state = false;

    let got_winch = Arc::new(AtomicBool::new(false));
    if is_tty {
        signal_hook::flag::register(SIGWINCH, Arc::clone(&got_winch)).ok();
    }

    while !done {
        if got_winch.load(Ordering::Relaxed) {
            forward_winsize(
                master.as_fd(),
                stderr.as_ref().map(|x| x.as_fd()),
                &mut stream_writer,
            )?;
            got_winch.store(false, Ordering::Relaxed);
        }

        let mut read_fds = FdSet::new();
        let mut timeout = TimeVal::new(2, 0); // 2 second timeout
        read_fds.insert(master.as_fd());
        if !read_stdin && is_tty {
            read_stdin = true;
        }
        if read_stdin {
            read_fds.insert(stdin.as_fd());
        }
        if let Some(ref f) = in_file {
            read_fds.insert(f.as_fd());
        }
        if let Some(ref fd) = stderr {
            read_fds.insert(fd.as_fd());
        }
        match select(None, Some(&mut read_fds), None, None, Some(&mut timeout)) {
            Ok(0) => {
                // Timeout occurred - check if we're waiting for input
                let is_waiting = heuristics.check_waiting_for_input();

                // Update session waiting state if it changed
                if is_waiting != current_waiting_state {
                    current_waiting_state = is_waiting;
                    if let Some(session_json_path) = session_json_path {
                        let _ = update_session_waiting(session_json_path, is_waiting);
                    }
                }

                // Send notification only once per waiting period
                if let Some(notification_writer) = &mut notification_writer {
                    if is_waiting && !input_notification_sent {
                        let event = NotificationEvent {
                            timestamp: jiff::Timestamp::now(),
                            event: "input_requested".to_string(),
                            data: serde_json::json!({
                                "title": "Input Requested",
                                "message": "The terminal appears to be waiting for input",
                                "debug_info": heuristics.get_debug_info()
                            }),
                        };

                        if notification_writer.write_notification(event).is_err() {
                            // Ignore notification write errors to not interrupt the main flow
                        }
                        input_notification_sent = true;
                    }
                }
                continue;
            }
            Err(Errno::EINTR | Errno::EAGAIN) => continue,
            Ok(_) => {}
            Err(err) => return Err(err),
        }

        if read_fds.contains(stdin.as_fd()) {
            match read(stdin.as_raw_fd(), &mut buf) {
                Ok(0) => {
                    send_eof_sequence(master.as_fd());
                    read_stdin = false;
                }
                Ok(n) => {
                    heuristics.record_input();
                    input_notification_sent = false; // Reset notification state on user input

                    // Update waiting state to false when there's input
                    if current_waiting_state {
                        current_waiting_state = false;
                        if let Some(session_json_path) = session_json_path {
                            let _ = update_session_waiting(session_json_path, false);
                        }
                    }

                    write_all(master.as_fd(), &buf[..n])?;
                }
                Err(Errno::EINTR | Errno::EAGAIN) => {}
                // on linux a closed tty raises EIO
                Err(Errno::EIO) => {
                    done = true;
                }
                Err(err) => return Err(err),
            };
        }
        if let Some(ref f) = in_file {
            if read_fds.contains(f.as_fd()) {
                // use read() here so that we can handle EAGAIN/EINTR
                // without this we might receive resource temporary unavailable
                // see https://github.com/mitsuhiko/teetty/issues/3
                match read(f.as_raw_fd(), &mut buf) {
                    Ok(0) | Err(Errno::EAGAIN | Errno::EINTR) => {}
                    Err(err) => return Err(err),
                    Ok(n) => {
                        heuristics.record_input();

                        // Update waiting state to false when there's input from FIFO
                        if current_waiting_state {
                            current_waiting_state = false;
                            if let Some(session_json_path) = session_json_path {
                                let _ = update_session_waiting(session_json_path, false);
                            }
                        }

                        write_all(master.as_fd(), &buf[..n])?;
                    }
                }
            }
        }
        if let Some(ref fd) = stderr {
            if read_fds.contains(fd.as_fd()) {
                match read(fd.as_raw_fd(), &mut buf) {
                    Ok(0) | Err(_) => {}
                    Ok(n) => {
                        forward_and_log(io::stderr().as_fd(), &mut None, &buf[..n], flush)?;
                    }
                }
            }
        }
        if read_fds.contains(master.as_fd()) {
            match read(master.as_raw_fd(), &mut buf) {
                // on linux a closed tty raises EIO
                Ok(0) | Err(Errno::EIO) => {
                    done = true;
                }
                Ok(n) => {
                    heuristics.record_output(&buf[..n]);
                    forward_and_log(io::stdout().as_fd(), &mut stream_writer, &buf[..n], flush)?
                }
                Err(Errno::EAGAIN | Errno::EINTR) => {}
                Err(err) => return Err(err),
            };
        }
    }

    Ok(match waitpid(child, None)? {
        WaitStatus::Exited(_, status) => status,
        WaitStatus::Signaled(_, signal, _) => 128 + signal as i32,
        _ => 1,
    })
}

fn forward_and_log(
    fd: BorrowedFd,
    stream_writer: &mut Option<&mut StreamWriter>,
    buf: &[u8],
    _flush: bool,
) -> Result<(), Errno> {
    if let Some(writer) = stream_writer {
        let time = writer.elapsed_time();
        let data = String::from_utf8_lossy(buf).to_string();
        let event = AsciinemaEvent {
            time,
            event_type: AsciinemaEventType::Output,
            data,
        };
        writer
            .write_event(event)
            .map_err(|x| match x.raw_os_error() {
                Some(errno) => Errno::from_raw(errno),
                None => Errno::EINVAL,
            })?;
    }

    write_all(fd, buf)?;
    Ok(())
}

/// Forwards the winsize and emits SIGWINCH
fn forward_winsize(
    master: BorrowedFd,
    stderr_master: Option<BorrowedFd>,
    stream_writer: &mut Option<&mut StreamWriter>,
) -> Result<(), Errno> {
    if let Some(winsize) = get_winsize(io::stdin().as_fd()) {
        set_winsize(master, winsize).ok();
        if let Some(second_master) = stderr_master {
            set_winsize(second_master, winsize).ok();
        }
        if let Ok(pgrp) = tcgetpgrp(master) {
            killpg(pgrp, Signal::SIGWINCH).ok();
        }

        // Log resize event to stream writer
        if let Some(writer) = stream_writer {
            let time = writer.elapsed_time();
            let event = AsciinemaEvent {
                time,
                event_type: AsciinemaEventType::Resize,
                data: format!("{}x{}", winsize.ws_col, winsize.ws_row),
            };
            writer
                .write_event(event)
                .map_err(|x| match x.raw_os_error() {
                    Some(errno) => Errno::from_raw(errno),
                    None => Errno::EINVAL,
                })?;
        }
    }
    Ok(())
}

/// If possible, returns the terminal size of the given fd.
fn get_winsize(fd: BorrowedFd) -> Option<Winsize> {
    nix::ioctl_read_bad!(_get_window_size, TIOCGWINSZ, Winsize);
    let mut size: Winsize = unsafe { std::mem::zeroed() };
    unsafe { _get_window_size(fd.as_raw_fd(), &mut size).ok()? };
    Some(size)
}

/// Sets the winsize
fn set_winsize(fd: BorrowedFd, winsize: Winsize) -> Result<(), Errno> {
    nix::ioctl_write_ptr_bad!(_set_window_size, TIOCSWINSZ, Winsize);
    unsafe { _set_window_size(fd.as_raw_fd(), &winsize) }?;
    Ok(())
}

/// Sends an EOF signal to the terminal if it's in canonical mode.
fn send_eof_sequence(fd: BorrowedFd) {
    if let Ok(attrs) = tcgetattr(fd) {
        if attrs.local_flags.contains(LocalFlags::ICANON) {
            write(fd, &[attrs.control_chars[VEOF]]).ok();
        }
    }
}

/// Calls write in a loop until it's done.
fn write_all(fd: BorrowedFd, mut buf: &[u8]) -> Result<(), Errno> {
    while !buf.is_empty() {
        // we generally assume that EINTR/EAGAIN can't happen on write()
        let n = write(fd, buf)?;
        buf = &buf[n..];
    }
    Ok(())
}

/// Creates a FIFO at the path if the file does not exist yet.
fn mkfifo_atomic(path: &Path) -> Result<(), Errno> {
    match mkfifo(path, Mode::S_IRUSR | Mode::S_IWUSR) {
        Ok(()) | Err(Errno::EEXIST) => Ok(()),
        Err(err) => Err(err),
    }
}

struct RestoreTerm(Termios);

impl Drop for RestoreTerm {
    fn drop(&mut self) {
        tcsetattr(io::stdin(), SetArg::TCSAFLUSH, &self.0).ok();
    }
}

/// Monitors a detached session by running a communication loop
fn monitor_detached_session(
    master: OwnedFd,
    session_json_path: Option<&Path>,
    mut notification_writer: Option<NotificationWriter>,
    mut stream_writer: Option<StreamWriter>,
    stdin_file: Option<File>,
) -> Result<(), Errno> {
    let mut buf = [0; 4096];
    let mut done = false;
    let mut heuristics = InputDetectionHeuristics::new();
    let mut input_notification_sent = false;
    let mut current_waiting_state = false;

    while !done {
        let mut read_fds = FdSet::new();
        let mut timeout = TimeVal::new(2, 0); // 2 second timeout
        read_fds.insert(master.as_fd());

        if let Some(ref f) = stdin_file {
            read_fds.insert(f.as_fd());
        }

        match select(None, Some(&mut read_fds), None, None, Some(&mut timeout)) {
            Ok(0) => {
                // Timeout occurred - check if we're waiting for input
                let is_waiting = heuristics.check_waiting_for_input();

                // Update session waiting state if it changed
                if is_waiting != current_waiting_state {
                    current_waiting_state = is_waiting;
                    if let Some(session_json_path) = session_json_path {
                        let _ = update_session_waiting(session_json_path, is_waiting);
                    }
                }

                // Send notification only once per waiting period
                if let Some(notification_writer) = &mut notification_writer {
                    if is_waiting && !input_notification_sent {
                        let event = NotificationEvent {
                            timestamp: jiff::Timestamp::now(),
                            event: "input_requested".to_string(),
                            data: serde_json::json!({
                                "title": "Input Requested",
                                "message": "The terminal appears to be waiting for input",
                                "debug_info": heuristics.get_debug_info()
                            }),
                        };

                        if notification_writer.write_notification(event).is_err() {
                            // Ignore notification write errors to not interrupt the main flow
                        }
                        input_notification_sent = true;
                    }
                }
                continue;
            }
            Err(Errno::EINTR | Errno::EAGAIN) => continue,
            Ok(_) => {}
            Err(err) => return Err(err),
        }

        if let Some(ref f) = stdin_file {
            if read_fds.contains(f.as_fd()) {
                match read(f.as_raw_fd(), &mut buf) {
                    Ok(0) | Err(Errno::EAGAIN | Errno::EINTR) => {}
                    Err(err) => return Err(err),
                    Ok(n) => {
                        heuristics.record_input();

                        // Update waiting state to false when there's input from FIFO
                        if current_waiting_state {
                            current_waiting_state = false;
                            if let Some(session_json_path) = session_json_path {
                                let _ = update_session_waiting(session_json_path, false);
                            }
                        }

                        write_all(master.as_fd(), &buf[..n])?;
                    }
                }
            }
        }

        if read_fds.contains(master.as_fd()) {
            match read(master.as_raw_fd(), &mut buf) {
                // on linux a closed tty raises EIO
                Ok(0) | Err(Errno::EIO) => {
                    done = true;
                }
                Ok(n) => {
                    heuristics.record_output(&buf[..n]);
                    // Only log to stream writer, don't write to stdout since we're detached
                    if let Some(writer) = &mut stream_writer {
                        let time = writer.elapsed_time();
                        let data = String::from_utf8_lossy(&buf[..n]).to_string();
                        let event = AsciinemaEvent {
                            time,
                            event_type: AsciinemaEventType::Output,
                            data,
                        };
                        writer
                            .write_event(event)
                            .map_err(|x| match x.raw_os_error() {
                                Some(errno) => Errno::from_raw(errno),
                                None => Errno::EINVAL,
                            })?;
                    }
                }
                Err(Errno::EAGAIN | Errno::EINTR) => {}
                Err(err) => return Err(err),
            };
        }
    }

    // Update session status to exited
    if let Some(session_json_path) = session_json_path {
        let _ = update_session_status(session_json_path, None, "exited", Some(0));
    }

    // Send session exited notification
    if let Some(ref mut notification_writer) = notification_writer {
        let notification = NotificationEvent {
            timestamp: Timestamp::now(),
            event: "session_exited".to_string(),
            data: serde_json::json!({
                "exit_code": 0
            }),
        };
        let _ = notification_writer.write_notification(notification);
    }

    Ok(())
}
