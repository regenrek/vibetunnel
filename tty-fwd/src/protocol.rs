use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{self, Command, Stdio};
use std::time::SystemTime;
use std::{fmt, fs};

use anyhow::Error;
use jiff::Timestamp;
use serde::de;
use serde::{Deserialize, Serialize};

use crate::tty_spawn::DEFAULT_TERM;

#[derive(Serialize, Deserialize, Default, Debug, Clone)]
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
    #[serde(default = "get_default_term")]
    pub term: String,
}

fn get_default_term() -> String {
    DEFAULT_TERM.to_string()
}

#[derive(Serialize, Deserialize, Debug, Clone)]
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
pub struct SessionEntryWithId {
    pub session_id: String,
    #[serde(flatten)]
    pub entry: SessionListEntry,
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
        Self {
            version: 2,
            width: 80,
            height: 24,
            timestamp: None,
            duration: None,
            command: None,
            title: None,
            env: None,
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

#[derive(Debug, Clone)]
pub enum AsciinemaEventType {
    Output,
    Input,
    Marker,
    Resize,
}

impl AsciinemaEventType {
    pub fn as_str(&self) -> &'static str {
        match self {
            AsciinemaEventType::Output => "o",
            AsciinemaEventType::Input => "i",
            AsciinemaEventType::Marker => "m",
            AsciinemaEventType::Resize => "r",
        }
    }

    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "o" => Ok(AsciinemaEventType::Output),
            "i" => Ok(AsciinemaEventType::Input),
            "m" => Ok(AsciinemaEventType::Marker),
            "r" => Ok(AsciinemaEventType::Resize),
            _ => Err(format!("Unknown event type: {}", s)),
        }
    }
}

#[derive(Debug, Clone)]
pub struct AsciinemaEvent {
    pub time: f64,
    pub event_type: AsciinemaEventType,
    pub data: String,
}

impl serde::Serialize for AsciinemaEvent {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeTuple;
        let mut tuple = serializer.serialize_tuple(3)?;
        tuple.serialize_element(&self.time)?;
        tuple.serialize_element(self.event_type.as_str())?;
        tuple.serialize_element(&self.data)?;
        tuple.end()
    }
}

impl<'de> serde::Deserialize<'de> for AsciinemaEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::{SeqAccess, Visitor};

        struct AsciinemaEventVisitor;

        impl<'de> Visitor<'de> for AsciinemaEventVisitor {
            type Value = AsciinemaEvent;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a tuple of [time, type, data]")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let time: f64 = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(0, &self))?;
                let event_type_str: String = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(1, &self))?;
                let data: String = seq
                    .next_element()?
                    .ok_or_else(|| de::Error::invalid_length(2, &self))?;

                let event_type = AsciinemaEventType::from_str(&event_type_str)
                    .map_err(|e| de::Error::custom(e))?;

                Ok(AsciinemaEvent {
                    time,
                    event_type,
                    data,
                })
            }
        }

        deserializer.deserialize_tuple(3, AsciinemaEventVisitor)
    }
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
    utf8_buffer: Vec<u8>,
}

impl StreamWriter {
    pub fn new(file: std::fs::File, header: AsciinemaHeader) -> Result<Self, Error> {
        use std::io::Write;
        let mut writer = Self {
            file,
            start_time: std::time::Instant::now(),
            utf8_buffer: Vec::new(),
        };
        let header_json = serde_json::to_string(&header)?;
        writeln!(&mut writer.file, "{header_json}")?;
        writer.file.flush()?;
        Ok(writer)
    }

    pub fn with_params(
        file: std::fs::File,
        width: u32,
        height: u32,
        command: Option<String>,
        title: Option<String>,
        env: Option<std::collections::HashMap<String, String>>,
    ) -> Result<Self, Error> {
        let header = AsciinemaHeader {
            version: 2,
            width,
            height,
            timestamp: Some(
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs(),
            ),
            duration: None,
            command,
            title,
            env,
            theme: None,
        };

        Self::new(file, header)
    }

    pub fn write_output(&mut self, buf: &[u8]) -> Result<(), Error> {
        let time = self.elapsed_time();

        // Combine any buffered bytes with the new buffer
        let mut combined_buf = std::mem::take(&mut self.utf8_buffer);
        combined_buf.extend_from_slice(buf);

        // Check if we have a complete UTF-8 sequence at the end
        match std::str::from_utf8(&combined_buf) {
            Ok(_) => {
                // Everything is valid UTF-8, process it all
                let data = String::from_utf8(combined_buf).unwrap();

                let event = AsciinemaEvent {
                    time,
                    event_type: AsciinemaEventType::Output,
                    data,
                };
                self.write_event(event)
            }
            Err(e) => {
                let valid_up_to = e.valid_up_to();

                if let Some(error_len) = e.error_len() {
                    // There's an invalid UTF-8 sequence at valid_up_to
                    // Process up to and including the invalid sequence lossily
                    let process_up_to = valid_up_to + error_len;
                    let remaining = &combined_buf[process_up_to..];

                    // Check if remaining bytes form an incomplete UTF-8 sequence (≤4 bytes)
                    if remaining.len() <= 4 && !remaining.is_empty() {
                        if let Err(e2) = std::str::from_utf8(remaining) {
                            if e2.error_len().is_none() && e2.valid_up_to() == 0 {
                                // Remaining bytes are an incomplete UTF-8 sequence, buffer them
                                let data = String::from_utf8_lossy(&combined_buf[..process_up_to])
                                    .to_string();
                                self.utf8_buffer.extend_from_slice(remaining);
                                let event = AsciinemaEvent {
                                    time,
                                    event_type: AsciinemaEventType::Output,
                                    data,
                                };
                                return self.write_event(event);
                            }
                        }
                    }

                    // Default: process everything lossily (invalid UTF-8 or remaining bytes are also invalid)
                    let event = AsciinemaEvent {
                        time,
                        event_type: AsciinemaEventType::Output,
                        data: String::from_utf8_lossy(&combined_buf).to_string(),
                    };
                    self.write_event(event)
                } else {
                    // Incomplete UTF-8 at the end
                    let incomplete_bytes = &combined_buf[valid_up_to..];

                    // Only buffer up to 4 bytes (max UTF-8 character size)
                    if incomplete_bytes.len() <= 4 {
                        // Process the valid portion
                        if valid_up_to > 0 {
                            let data =
                                String::from_utf8_lossy(&combined_buf[..valid_up_to]).to_string();
                            self.utf8_buffer.extend_from_slice(incomplete_bytes);

                            let event = AsciinemaEvent {
                                time,
                                event_type: AsciinemaEventType::Output,
                                data,
                            };
                            self.write_event(event)
                        } else {
                            // Only incomplete bytes, buffer them
                            self.utf8_buffer.extend_from_slice(incomplete_bytes);
                            Ok(())
                        }
                    } else {
                        // Too many incomplete bytes, process everything lossily

                        let event = AsciinemaEvent {
                            time,
                            event_type: AsciinemaEventType::Output,
                            data: String::from_utf8_lossy(&combined_buf).to_string(),
                        };
                        self.write_event(event)
                    }
                }
            }
        }
    }

    pub fn write_event(&mut self, event: AsciinemaEvent) -> Result<(), Error> {
        use std::io::Write;

        let event_json = serde_json::to_string(&event)?;
        writeln!(self.file, "{event_json}")?;
        self.file.flush()?;

        Ok(())
    }

    pub fn elapsed_time(&self) -> f64 {
        self.start_time.elapsed().as_secs_f64()
    }
}

pub struct NotificationWriter {
    file: std::fs::File,
}

impl NotificationWriter {
    pub const fn new(file: std::fs::File) -> Self {
        Self { file }
    }

    pub fn write_notification(&mut self, event: NotificationEvent) -> Result<(), std::io::Error> {
        use std::io::Write;

        let event_json = serde_json::to_string(&event)?;
        writeln!(self.file, "{event_json}")?;
        self.file.flush()?;

        Ok(())
    }
}

#[derive(Debug, Clone)]
pub enum StreamEvent {
    Header(AsciinemaHeader),
    Terminal(AsciinemaEvent),
    Error { message: String },
    End,
}

// Error event JSON structure for serde
#[derive(Serialize, Deserialize, Debug, Clone)]
struct ErrorEvent {
    #[serde(rename = "type")]
    event_type: String,
    message: String,
}

// End event JSON structure for serde
#[derive(Serialize, Deserialize, Debug, Clone)]
struct EndEvent {
    #[serde(rename = "type")]
    event_type: String,
}

impl serde::Serialize for StreamEvent {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            StreamEvent::Header(header) => header.serialize(serializer),
            StreamEvent::Terminal(event) => event.serialize(serializer),
            StreamEvent::Error { message } => {
                let error_event = ErrorEvent {
                    event_type: "error".to_string(),
                    message: message.clone(),
                };
                error_event.serialize(serializer)
            }
            StreamEvent::End => {
                let end_event = EndEvent {
                    event_type: "end".to_string(),
                };
                end_event.serialize(serializer)
            }
        }
    }
}

impl<'de> serde::Deserialize<'de> for StreamEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value: serde_json::Value = serde_json::Value::deserialize(deserializer)?;

        // Try to parse as header first (has version and width fields)
        if value.get("version").is_some() && value.get("width").is_some() {
            let header: AsciinemaHeader = serde_json::from_value(value)
                .map_err(|e| de::Error::custom(format!("Failed to parse header: {}", e)))?;
            return Ok(StreamEvent::Header(header));
        }

        // Try to parse as an event array [timestamp, type, data]
        if let Some(arr) = value.as_array() {
            if arr.len() >= 3 {
                let event: AsciinemaEvent = serde_json::from_value(value).map_err(|e| {
                    de::Error::custom(format!("Failed to parse terminal event: {}", e))
                })?;
                return Ok(StreamEvent::Terminal(event));
            }
        }

        // Try to parse as error or end event
        if let Some(obj) = value.as_object() {
            if let Some(event_type) = obj.get("type").and_then(|v| v.as_str()) {
                match event_type {
                    "error" => {
                        let error_event: ErrorEvent =
                            serde_json::from_value(value).map_err(|e| {
                                de::Error::custom(format!("Failed to parse error event: {}", e))
                            })?;
                        return Ok(StreamEvent::Error {
                            message: error_event.message,
                        });
                    }
                    "end" => {
                        return Ok(StreamEvent::End);
                    }
                    _ => {}
                }
            }
        }

        Err(de::Error::custom("Unrecognized stream event format"))
    }
}

impl StreamEvent {
    pub fn from_json_line(line: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let line = line.trim();
        if line.is_empty() {
            return Err("Empty line".into());
        }

        let event: StreamEvent = serde_json::from_str(line)?;
        Ok(event)
    }
}

#[derive(Debug)]
enum StreamingState {
    ReadingExisting(BufReader<std::fs::File>),
    InitializingTail,
    Streaming {
        reader: BufReader<process::ChildStdout>,
        child: process::Child,
    },
    Error(String),
    Finished,
}

pub struct StreamingIterator {
    stream_path: String,
    start_time: SystemTime,
    state: StreamingState,
}

impl StreamingIterator {
    pub fn new(stream_path: String) -> Self {
        let state = if let Ok(file) = fs::File::open(&stream_path) {
            StreamingState::ReadingExisting(BufReader::new(file))
        } else {
            StreamingState::InitializingTail
        };

        Self {
            stream_path,
            start_time: SystemTime::now(),
            state,
        }
    }
}

impl Iterator for StreamingIterator {
    type Item = StreamEvent;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match &mut self.state {
                StreamingState::ReadingExisting(reader) => {
                    let mut line = String::new();
                    match reader.read_line(&mut line) {
                        Ok(0) => {
                            // End of file, switch to tail mode
                            self.state = StreamingState::InitializingTail;
                            continue;
                        }
                        Ok(_) => {
                            if let Ok(mut event) = StreamEvent::from_json_line(&line) {
                                // Convert terminal events to instant playback (time = 0)
                                if let StreamEvent::Terminal(ref mut term_event) = event {
                                    term_event.time = 0.0;
                                }
                                return Some(event);
                            }
                            // If parsing fails, continue to next line
                            continue;
                        }
                        Err(e) => {
                            self.state =
                                StreamingState::Error(format!("Error reading file: {}", e));
                            continue;
                        }
                    }
                }
                StreamingState::InitializingTail => {
                    match Command::new("tail")
                        .args(["-f", &self.stream_path])
                        .stdout(Stdio::piped())
                        .spawn()
                    {
                        Ok(mut child) => {
                            if let Some(stdout) = child.stdout.take() {
                                self.state = StreamingState::Streaming {
                                    reader: BufReader::new(stdout),
                                    child,
                                };
                                continue;
                            } else {
                                self.state =
                                    StreamingState::Error("Failed to get tail stdout".to_string());
                                continue;
                            }
                        }
                        Err(e) => {
                            self.state = StreamingState::Error(format!(
                                "Failed to start tail command: {}",
                                e
                            ));
                            continue;
                        }
                    }
                }
                StreamingState::Streaming { reader, child: _ } => {
                    let mut line = String::new();
                    match reader.read_line(&mut line) {
                        Ok(0) => {
                            // End of stream
                            self.state = StreamingState::Finished;
                            return Some(StreamEvent::End);
                        }
                        Ok(_) => {
                            if line.trim().is_empty() {
                                continue;
                            }

                            match StreamEvent::from_json_line(&line) {
                                Ok(mut event) => {
                                    if matches!(event, StreamEvent::Header(_)) {
                                        continue;
                                    }
                                    if let StreamEvent::Terminal(ref mut term_event) = event {
                                        let current_time = SystemTime::now()
                                            .duration_since(SystemTime::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_secs_f64();
                                        let stream_start_time = self
                                            .start_time
                                            .duration_since(SystemTime::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_secs_f64();
                                        term_event.time = current_time - stream_start_time;
                                    }
                                    return Some(event);
                                }
                                Err(err) => {
                                    self.state = StreamingState::Error(format!(
                                        "Error parsing JSON: {}",
                                        err
                                    ));
                                    continue;
                                }
                            }
                        }
                        Err(e) => {
                            self.state =
                                StreamingState::Error(format!("Error reading from tail: {}", e));
                            continue;
                        }
                    }
                }
                StreamingState::Error(message) => {
                    let error_message = message.clone();
                    self.state = StreamingState::Finished;
                    return Some(StreamEvent::Error {
                        message: error_message,
                    });
                }
                StreamingState::Finished => {
                    return None;
                }
            }
        }
    }
}

impl Drop for StreamingIterator {
    fn drop(&mut self) {
        if let StreamingState::Streaming { child, .. } = &mut self.state {
            let _ = child.kill();
        }
    }
}
