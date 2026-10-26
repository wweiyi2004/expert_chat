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
    load_with_warning().0
}
pub fn load_with_warning() -> (Config, Option<String>) {
    load_from(&path())
}
fn load_from(path: &std::path::Path) -> (Config, Option<String>) {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (Config::default(), None);
        }
        Err(_) => {
            return (
                Config::default(),
                Some(
                    "无法读取终端配置，已使用默认值；请检查 EXPERT_TUI_CONFIG 或用户配置目录"
                        .into(),
                ),
            );
        }
    };
    match serde_json::from_slice::<Config>(&data) {
        Ok(config) if matches!(config.ambiguous_width, 1 | 2)
            && matches!(config.pet.as_str(), "none" | "megumin") => (config, None),
        Ok(_) => (Config::default(), Some("终端配置取值无效，已使用默认值：pet 仅支持 megumin/none，ambiguous_width 仅支持 1/2".into())),
        Err(_) => (Config::default(), Some("终端配置 JSON 损坏，已使用默认值；原配置文件未被改写".into())),
    }
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

#[cfg(test)]
mod repair_tests {
    use super::*;
    #[test]
    fn malformed_configuration_is_reported_without_overwriting_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tui.json");
        std::fs::write(&path, b"{broken").unwrap();
        let (config, warning) = load_from(&path);
        assert_eq!(config.pet, "megumin");
        assert!(warning.unwrap().contains("JSON"));
        assert_eq!(std::fs::read(&path).unwrap(), b"{broken");
    }
    #[test]
    fn missing_configuration_is_normal_but_invalid_settings_are_reported() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tui.json");
        assert!(load_from(&path).1.is_none());
        std::fs::write(&path, br#"{"pet":"none","ambiguous_width":0}"#).unwrap();
        assert!(load_from(&path).1.is_some());
        std::fs::write(&path, br#"{"pet":"none","ambiguous_width":2}"#).unwrap();
        let (config, warning) = load_from(&path);
        assert_eq!(config.pet, "none");
        assert_eq!(config.ambiguous_width, 2);
        assert!(warning.is_none());
    }
}
