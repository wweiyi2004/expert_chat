use serde::{Deserialize, Serialize};
use std::path::PathBuf;
#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub pet: String,
    pub ambiguous_width: u8,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            pet: "megumin".into(),
            ambiguous_width: 1,
        }
    }
}
pub fn path() -> PathBuf {
    std::env::var_os("EXPERT_TUI_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("APPDATA")
                .or_else(|| std::env::var_os("XDG_CONFIG_HOME"))
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    std::env::var_os("HOME")
                        .map(PathBuf::from)
                        .unwrap_or_default()
                        .join(".config")
                })
                .join("expert-chat")
                .join("tui.json")
        })
}
pub fn load() -> Config {
    std::fs::read(path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
pub fn save_pet(enabled: bool) -> anyhow::Result<()> {
    let mut c = load();
    c.pet = if enabled { "megumin" } else { "none" }.into();
    let p = path();
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(p, serde_json::to_vec_pretty(&c)?)?;
    Ok(())
}
