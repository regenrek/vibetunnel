use anyhow::Result;
use serde_json::json;
use std::process::Command;
use uuid::Uuid;

/// Spawns a terminal command by invoking the VibeTunnel app with CLI arguments.
///
/// This approach bypasses the distributed notification system which has restrictions
/// on macOS 15 (Sequoia) and later. Instead, it directly invokes the VibeTunnel app
/// with command-line arguments.
/// 
/// # Command Format
/// 
/// The VibeTunnel app is invoked with:
/// ```
/// VibeTunnel spawn-terminal '{"command": [...], "workingDir": "...", "sessionId": "..."}'
/// ```
/// 
/// # Arguments
/// 
/// * `command` - Array of command arguments to execute
/// * `working_dir` - Optional working directory path
/// * `vibetunnel_path` - Optional path to the VibeTunnel executable
/// 
/// # Returns
/// 
/// Returns the session ID on success, or an error if the invocation fails
pub fn spawn_terminal_command(command: &[String], working_dir: Option<&str>, vibetunnel_path: Option<&str>) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();
    
    // Construct the JSON payload
    let mut payload = json!({
        "command": command,
        "sessionId": session_id
    });
    
    if let Some(wd) = working_dir {
        payload["workingDir"] = json!(wd);
    }
    
    let json_string = serde_json::to_string(&payload)?;
    
    // Use provided path or find VibeTunnel app path
    let vibetunnel_executable = if let Some(path) = vibetunnel_path {
        // Validate that the provided path exists
        if !std::path::Path::new(path).exists() {
            return Err(anyhow::anyhow!("Provided VibeTunnel path does not exist: {}", path));
        }
        path.to_string()
    } else {
        find_vibetunnel_app()?
    };
    
    println!("Spawning terminal session {} via CLI invocation", session_id);
    println!("VibeTunnel path: {}", vibetunnel_executable);
    println!("Payload: {}", json_string);
    
    // Invoke VibeTunnel with spawn-terminal command
    let output = Command::new(&vibetunnel_executable)
        .arg("spawn-terminal")
        .arg(&json_string)
        .output()?;
    
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow::anyhow!("Failed to spawn terminal: {}", stderr));
    }
    
    let stdout = String::from_utf8_lossy(&output.stdout);
    if stdout.contains("successfully") {
        println!("Terminal spawned successfully for session: {}", session_id);
    }
    
    Ok(session_id)
}

/// Finds the path to the VibeTunnel app executable
fn find_vibetunnel_app() -> Result<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    
    // Try common locations for macOS apps
    let user_apps_path = format!("{}/Applications/VibeTunnel.app/Contents/MacOS/VibeTunnel", home);
    let derived_data_debug = format!("{}/Library/Developer/Xcode/DerivedData/VibeTunnel-*/Build/Products/Debug/VibeTunnel.app/Contents/MacOS/VibeTunnel", home);
    let derived_data_release = format!("{}/Library/Developer/Xcode/DerivedData/VibeTunnel-*/Build/Products/Release/VibeTunnel.app/Contents/MacOS/VibeTunnel", home);
    
    let possible_paths = vec![
        // Check if VibeTunnel is in PATH (e.g., via symlink)
        "VibeTunnel",
        // Standard Applications folder
        "/Applications/VibeTunnel.app/Contents/MacOS/VibeTunnel",
        // User Applications folder
        &user_apps_path,
        // Development build location (relative to tty-fwd)
        "../VibeTunnel/build/Debug/VibeTunnel.app/Contents/MacOS/VibeTunnel",
        "../VibeTunnel/build/Release/VibeTunnel.app/Contents/MacOS/VibeTunnel",
        // Xcode DerivedData (common development location)
        &derived_data_debug,
        &derived_data_release,
    ];
    
    // First try to find it in PATH
    if let Ok(output) = Command::new("which").arg("VibeTunnel").output() {
        if output.status.success() {
            if let Ok(path) = String::from_utf8(output.stdout) {
                let path = path.trim();
                if !path.is_empty() {
                    return Ok(path.to_string());
                }
            }
        }
    }
    
    // Try each possible path
    for path in &possible_paths {
        // Handle glob patterns for DerivedData
        if path.contains("*") {
            if let Ok(entries) = glob::glob(path) {
                for entry in entries.filter_map(Result::ok) {
                    if entry.exists() {
                        return Ok(entry.to_string_lossy().to_string());
                    }
                }
            }
        } else if std::path::Path::new(path).exists() {
            // For non-glob paths, check directly
            if *path == "VibeTunnel" {
                // If just "VibeTunnel", use full path resolution
                return Ok("VibeTunnel".to_string());
            }
            return Ok(path.to_string());
        }
    }
    
    Err(anyhow::anyhow!(
        "VibeTunnel app not found. Please ensure VibeTunnel is installed in /Applications or add it to your PATH"
    ))
}
