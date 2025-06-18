use anyhow::Result;

/// Spawns a terminal command by communicating with VibeTunnel via Unix domain socket.
///
/// This approach uses a Unix domain socket at `/tmp/vibetunnel-terminal.sock` to
/// communicate with the running VibeTunnel application, which handles the actual
/// terminal spawning.
///
/// # Arguments
///
/// * `command` - Array of command arguments to execute
/// * `working_dir` - Optional working directory path
/// * `_vibetunnel_path` - Kept for API compatibility but no longer used
///
/// # Returns
///
/// Returns the session ID on success, or an error if the socket communication fails
pub fn spawn_terminal_command(
    command: &[String],
    working_dir: Option<&str>,
    _vibetunnel_path: Option<&str>, // Kept for API compatibility, no longer used
) -> Result<String> {
    // Use the socket approach to communicate with VibeTunnel
    crate::term_socket::spawn_terminal_via_socket(command, working_dir)
}