use std::collections::HashMap;
use std::path::Path;
use std::{fs};

use crate::protocol::SessionListEntry;

pub fn list_sessions(control_path: &Path) -> Result<HashMap<String, SessionListEntry>, anyhow::Error> {
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