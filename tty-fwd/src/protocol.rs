use serde::Serialize;

#[derive(Serialize)]
pub struct SessionInfo {
    pub cmdline: Vec<String>,
    pub name: String,
    pub cwd: String,
}
