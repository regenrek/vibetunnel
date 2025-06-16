use jiff::Timestamp;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Serialize, Deserialize, Default)]
pub struct SessionInfo {
    pub cmdline: Vec<String>,
    pub name: String,
    pub cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<Timestamp>,
    #[serde(default)]
    pub waiting: bool,
    #[serde(default = "default_term")]
    pub term: String,
}

fn default_term() -> String {
    "xterm".to_string()
}

#[derive(Serialize)]
pub struct SessionListEntry {
    #[serde(flatten)]
    pub session_info: SessionInfo,
    #[serde(rename = "stream-out")]
    pub stream_out: String,
    pub stdin: String,
    #[serde(rename = "notification-stream")]
    pub notification_stream: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AsciinemaHeader {
    pub version: u32,
    pub width: u32,
    pub height: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub theme: Option<AsciinemaTheme>,
}

impl Default for AsciinemaHeader {
    fn default() -> Self {
        let mut env = HashMap::new();
        env.insert("TERM".to_string(), "xterm".to_string());

        Self {
            version: 2,
            width: 80,
            height: 24,
            timestamp: None,
            duration: None,
            command: None,
            title: None,
            env: Some(env),
            theme: None,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AsciinemaTheme {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub palette: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(tag = "type")]
pub enum AsciinemaEventType {
    #[serde(rename = "o")]
    Output,
    #[serde(rename = "i")]
    Input,
    #[serde(rename = "m")]
    Marker,
    #[serde(rename = "r")]
    Resize,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AsciinemaEvent {
    pub time: f64,
    pub event_type: AsciinemaEventType,
    pub data: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct NotificationEvent {
    pub timestamp: Timestamp,
    pub event: String,
    pub data: serde_json::Value,
}

pub struct StreamWriter {
    file: std::fs::File,
    start_time: std::time::Instant,
    header: Option<AsciinemaHeader>,
    header_written: bool,
}

impl StreamWriter {
    pub fn new(file: std::fs::File, header: AsciinemaHeader) -> Result<Self, std::io::Error> {
        Ok(Self {
            file,
            start_time: std::time::Instant::now(),
            header: Some(header),
            header_written: false,
        })
    }

    pub fn write_event(&mut self, event: AsciinemaEvent) -> Result<(), std::io::Error> {
        use std::io::Write;

        // Write header if not already written
        if !self.header_written {
            self.write_header()?;
        }

        let event_array = [
            serde_json::json!(event.time),
            serde_json::json!(match event.event_type {
                AsciinemaEventType::Output => "o",
                AsciinemaEventType::Input => "i",
                AsciinemaEventType::Marker => "m",
                AsciinemaEventType::Resize => "r",
            }),
            serde_json::json!(event.data),
        ];

        let event_json = serde_json::to_string(&event_array)?;
        writeln!(self.file, "{}", event_json)?;
        self.file.flush()?;

        Ok(())
    }

    fn write_header(&mut self) -> Result<(), std::io::Error> {
        use std::io::Write;

        if let Some(header) = self.header.take() {
            let header_json = serde_json::to_string(&header)?;
            writeln!(self.file, "{}", header_json)?;
            self.file.flush()?;
            self.header_written = true;
        }
        Ok(())
    }

    pub fn elapsed_time(&self) -> f64 {
        self.start_time.elapsed().as_secs_f64()
    }

    /// Force write the header if it hasn't been written yet
    pub fn ensure_header_written(&mut self) -> Result<(), std::io::Error> {
        if !self.header_written {
            self.write_header()?;
        }
        Ok(())
    }
}

pub struct NotificationWriter {
    file: std::fs::File,
}

impl NotificationWriter {
    pub fn new(file: std::fs::File) -> Self {
        Self { file }
    }

    pub fn write_notification(&mut self, event: NotificationEvent) -> Result<(), std::io::Error> {
        use std::io::Write;

        let event_json = serde_json::to_string(&event)?;
        writeln!(self.file, "{}", event_json)?;
        self.file.flush()?;

        Ok(())
    }
}
