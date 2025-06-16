use std::time::{Duration, Instant};

/// A buffer that safely handles UTF-8 sequences, including partial ones
#[derive(Debug, Clone)]
struct Utf8Buffer {
    data: Vec<u8>,
    max_len: usize,
}

impl Utf8Buffer {
    fn new(max_len: usize) -> Self {
        Self {
            data: Vec::new(),
            max_len,
        }
    }

    fn push_bytes(&mut self, bytes: &[u8]) {
        self.data.extend_from_slice(bytes);
        self.truncate_to_valid_utf8();
    }

    fn truncate_to_valid_utf8(&mut self) {
        if self.data.len() <= self.max_len {
            return;
        }

        // Find a safe truncation point that preserves UTF-8 boundaries
        let target_len = self.max_len;
        let mut truncate_at = target_len;

        // Work backwards from target length to find a valid UTF-8 boundary
        while truncate_at > 0 {
            if std::str::from_utf8(&self.data[self.data.len() - truncate_at..]).is_ok() {
                break;
            }
            truncate_at -= 1;
        }

        if truncate_at > 0 {
            let start = self.data.len() - truncate_at;
            self.data = self.data[start..].to_vec();
        } else {
            // If we can't find a valid boundary, clear the buffer
            self.data.clear();
        }
    }

    fn as_str(&self) -> &str {
        // Return the valid UTF-8 portion, replacing invalid sequences
        std::str::from_utf8(&self.data).unwrap_or("")
    }

}

#[derive(Debug, Clone)]
pub struct InputDetectionHeuristics {
    last_output_time: Option<Instant>,
    last_input_time: Option<Instant>,
    idle_threshold: Duration,
    prompt_patterns: Vec<&'static str>,
    recent_output: Utf8Buffer,
    consecutive_idle_periods: u32,
}

impl Default for InputDetectionHeuristics {
    fn default() -> Self {
        Self {
            last_output_time: None,
            last_input_time: None,
            idle_threshold: Duration::from_millis(500),
            prompt_patterns: vec![
                "$ ",
                "# ",
                "> ",
                "? ",
                ": ",
                ">> ",
                ">>> ",
                "Password:",
                "password:",
                "Enter ",
                "Please enter",
                "Continue?",
                "(y/n)",
                "[y/N]",
                "[Y/n]",
                "Press any key",
                "Do you want to",
            ],
            recent_output: Utf8Buffer::new(512),
            consecutive_idle_periods: 0,
        }
    }
}

impl InputDetectionHeuristics {
    pub fn new() -> Self {
        Self::default()
    }


    pub fn record_output(&mut self, data: &[u8]) {
        self.last_output_time = Some(Instant::now());
        self.consecutive_idle_periods = 0;

        // Always push the raw bytes, even if they contain invalid UTF-8
        self.recent_output.push_bytes(data);
    }

    pub fn record_input(&mut self) {
        self.last_input_time = Some(Instant::now());
    }

    pub fn check_waiting_for_input(&mut self) -> bool {
        let now = Instant::now();
        
        let is_idle = match self.last_output_time {
            Some(last_output) => now.duration_since(last_output) >= self.idle_threshold,
            None => false,
        };

        if is_idle {
            self.consecutive_idle_periods += 1;
        }

        let has_prompt_pattern = self.detect_prompt_pattern();
        
        let recent_activity = match (self.last_input_time, self.last_output_time) {
            (Some(input_time), Some(output_time)) => {
                let since_input = now.duration_since(input_time);
                let since_output = now.duration_since(output_time);
                
                since_input > Duration::from_millis(100) && 
                since_output > Duration::from_millis(100) &&
                since_output >= self.idle_threshold
            }
            (None, Some(output_time)) => {
                now.duration_since(output_time) >= self.idle_threshold
            }
            _ => false,
        };

        let confidence_score = self.calculate_confidence_score(is_idle, has_prompt_pattern, recent_activity);
        
        confidence_score >= 0.6
    }

    fn detect_prompt_pattern(&self) -> bool {
        let recent_lines = self.get_recent_lines(3);
        
        for line in &recent_lines {
            // Check both trimmed and untrimmed versions
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            for pattern in &self.prompt_patterns {
                if line.ends_with(pattern) || line.contains(pattern) || 
                   trimmed.ends_with(pattern.trim()) || trimmed.contains(pattern) {
                    return true;
                }
            }

            if self.looks_like_prompt(trimmed) {
                return true;
            }
        }

        false
    }

    fn looks_like_prompt(&self, line: &str) -> bool {
        let line = line.trim();
        
        if line.is_empty() {
            return false;
        }

        if line.ends_with(':') && line.len() < 50 {
            return true;
        }

        if line.ends_with('?') && line.len() < 100 {
            return true;
        }

        let words = line.split_whitespace().collect::<Vec<_>>();
        if words.len() <= 5 && (
            line.contains("enter") || 
            line.contains("input") || 
            line.contains("type") ||
            line.contains("choose") ||
            line.contains("select")
        ) {
            return true;
        }

        false
    }

    fn get_recent_lines(&self, max_lines: usize) -> Vec<String> {
        self.recent_output
            .as_str()
            .lines()
            .rev()
            .take(max_lines)
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    }

    fn calculate_confidence_score(&self, is_idle: bool, has_prompt: bool, recent_activity: bool) -> f32 {
        let mut score: f32 = 0.0;

        if is_idle {
            score += 0.3;
        }

        if has_prompt {
            score += 0.5;
        }

        if recent_activity {
            score += 0.2;
        }

        if self.consecutive_idle_periods >= 2 {
            score += 0.1;
        }

        if self.consecutive_idle_periods >= 5 {
            score += 0.1;
        }

        score.min(1.0)
    }


    pub fn get_debug_info(&self) -> String {
        format!(
            "Heuristics Debug: last_output={:?}, consecutive_idle={}, recent_output_len={}, patterns_detected={}",
            self.last_output_time.map(|t| t.elapsed()),
            self.consecutive_idle_periods,
            self.recent_output.as_str().len(),
            self.detect_prompt_pattern()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prompt_detection() {
        let mut heuristics = InputDetectionHeuristics::new();
        
        heuristics.record_output(b"user@host:~$ ");
        // Wait enough to trigger idle detection
        std::thread::sleep(Duration::from_millis(600));
        assert!(heuristics.check_waiting_for_input());
        
        let mut heuristics = InputDetectionHeuristics::new();
        heuristics.record_output(b"Password: ");
        std::thread::sleep(Duration::from_millis(600));
        assert!(heuristics.check_waiting_for_input());
        
        let mut heuristics = InputDetectionHeuristics::new();
        heuristics.record_output(b"Do you want to continue? (y/n) ");
        std::thread::sleep(Duration::from_millis(600));
        assert!(heuristics.check_waiting_for_input());
    }

    #[test]
    fn test_idle_detection() {
        let mut heuristics = InputDetectionHeuristics::new();
        heuristics.idle_threshold = Duration::from_millis(100);
        
        heuristics.record_output(b"$ ");
        assert!(!heuristics.check_waiting_for_input());
        
        std::thread::sleep(Duration::from_millis(150));
        assert!(heuristics.check_waiting_for_input());
    }
}