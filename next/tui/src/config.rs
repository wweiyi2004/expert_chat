use serde::{Deserialize, Serialize};
use std::path::PathBuf;
#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub pet: String,
    pub ambiguous_width: u8,
    pub skin: String,
    pub background: Option<String>,
    pub accent: Option<String>,
    pub code_style: String,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            pet: "megumin".into(),
            ambiguous_width: 1,
            skin: "terminal".into(),
            background: None,
            accent: None,
            code_style: "auto".into(),
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
            && matches!(config.pet.as_str(), "none" | "megumin")
            && valid_appearance(&config) => (config, None),
        Ok(_) => (Config::default(), Some("终端配置取值无效，已使用默认值；请通过 /skin 选择皮肤和 #RRGGBB 颜色，字符宽度仅支持 1/2".into())),
        Err(_) => (Config::default(), Some("终端配置 JSON 损坏，已使用默认值；原配置文件未被改写".into())),
    }
}
fn valid_appearance(c: &Config) -> bool {
    crate::theme::SKINS.iter().any(|(id, _)| *id == c.skin)
        && crate::theme::CODE_STYLES
            .iter()
            .any(|(id, _)| *id == c.code_style)
        && [&c.background, &c.accent].into_iter().all(|v| {
            v.as_deref()
                .is_none_or(|s| crate::theme::parse_color(s).is_some())
        })
}
fn save(config: &Config) -> anyhow::Result<()> {
    let p = path();
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)?;
    }
    use std::io::Write;
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let temporary = p.with_extension(format!("json.{}.{}.tmp", std::process::id(), suffix));
    let result = (|| -> anyhow::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec_pretty(config)?)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, &p)?;
        Ok(())
    })();
    if temporary.exists() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
pub fn save_skin(skin: &str) -> anyhow::Result<Config> {
    let c = load();
    save_appearance(skin, None, None, &c.code_style)
}
pub fn save_appearance(
    skin: &str,
    background: Option<&str>,
    accent: Option<&str>,
    code_style: &str,
) -> anyhow::Result<Config> {
    let mut c = load();
    c.skin = skin.into();
    c.background = background
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_owned());
    c.accent = accent
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_owned());
    c.code_style = code_style.into();
    anyhow::ensure!(
        valid_appearance(&c),
        "皮肤或代码样式无效；自定义颜色请填写 #RRGGBB，留空跟随皮肤"
    );
    save(&c)?;
    Ok(c)
}
pub fn save_pet(enabled: bool) -> anyhow::Result<()> {
    let mut c = load();
    c.pet = if enabled { "megumin" } else { "none" }.into();
    save(&c)
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
