use anyhow::anyhow;
use std::process::Command;
use std::str::FromStr;

pub enum Terminal {
    TerminalApp,
    Ghostty,
}

impl Terminal {
    pub fn path(&self) -> &str {
        match self {
            Terminal::TerminalApp => "/System/Applications/Utilities/Terminal.app",
            Terminal::Ghostty => "/Applications/Ghostty.app",
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Terminal::TerminalApp => "Terminal.app",
            Terminal::Ghostty => "Ghostty",
        }
    }
}

impl FromStr for Terminal {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "terminal" | "terminal.app" => Ok(Terminal::TerminalApp),
            "ghostty" | "ghostty.app" => Ok(Terminal::Ghostty),
            _ => Err(anyhow::anyhow!("Unsupported terminal application: {}", s)),
        }
    }
}

pub fn spawn_terminal(
    terminal: &str,
    control_path: &std::path::PathBuf,
    session_name: Option<String>,
) -> Result<i32, anyhow::Error> {
    let terminal = Terminal::from_str(terminal)?;
    let terminal_path = terminal.path();

    // Build the command line for the terminal application
    let mut tty_fwd_cmd = Vec::new();
    tty_fwd_cmd.push(
        std::env::current_exe()
            .unwrap()
            .to_string_lossy()
            .to_string(),
    );
    tty_fwd_cmd.push("--control-path".to_string());
    tty_fwd_cmd.push(control_path.to_string_lossy().to_string());

    if let Some(name) = session_name {
        tty_fwd_cmd.push("--session-name".to_string());
        tty_fwd_cmd.push(name);
    }

    tty_fwd_cmd.push("--".to_string());
    tty_fwd_cmd.push("${SHELL:-/bin/bash}".to_string());

    // Check if the terminal application exists
    if !std::path::Path::new(&terminal_path).exists() {
        return Err(anyhow!(
            "Terminal application not found: {}",
            terminal.name()
        ));
    }

    // Use osascript to open the terminal and run the command
    let script = match terminal {
        Terminal::TerminalApp => {
            format!(
                r#"tell application "Terminal"
    activate
    do script "{} && exit"
end tell"#,
                shell_escape(&tty_fwd_cmd.join(" "))
            )
        }
        Terminal::Ghostty => {
            format!(
                r#"tell application "Ghostty"
    activate
    tell application "System Events"
        keystroke "t" using command down
        delay 0.2
        keystroke "{} && exit"
        keystroke return
    end tell
end tell"#,
                shell_escape(&format!("{}", tty_fwd_cmd.join(" ")))
            )
        }
    };

    // First, open the terminal application
    let open_result = Command::new("open").arg(&terminal_path).output()?;

    if !open_result.status.success() {
        return Err(anyhow!(
            "Failed to open terminal application: {}",
            String::from_utf8_lossy(&open_result.stderr)
        ));
    }

    // Give the terminal a moment to open
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Run the osascript command
    let osascript_result = Command::new("osascript").arg("-e").arg(&script).output()?;

    if !osascript_result.status.success() {
        return Err(anyhow!(
            "Failed to execute osascript: {}",
            String::from_utf8_lossy(&osascript_result.stderr)
        ));
    }

    // Return 0 for success since we launched the terminal
    Ok(0)
}

fn shell_escape(s: &str) -> String {
    s.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("'", "\\'")
}
