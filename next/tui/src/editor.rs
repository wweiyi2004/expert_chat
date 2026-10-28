use anyhow::{Context, Result, bail};
use std::{
    io::Write,
    process::{Child, Command},
};
use tempfile::TempPath;

pub struct Editor {
    child: Child,
    file: Option<TempPath>,
    confirm_return: bool,
    confirmed: bool,
}
impl Drop for Editor {
    fn drop(&mut self) {
        // An interrupted edit must not delete a file still open in a GUI editor.
        if let Some(file) = self.file.take() {
            let _ = file.keep();
        }
    }
}
/// Parse an executable and literal arguments without invoking a command shell.
/// Backslashes remain literal, including Windows paths inside double quotes.
pub fn arguments(value: &str) -> Result<Vec<String>> {
    let mut words = vec![];
    let mut word = String::new();
    let mut quote = None;
    let mut started = false;
    for c in value.chars() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else {
                word.push(c);
            }
        } else if c == '\'' || c == '"' {
            quote = Some(c);
            started = true;
        } else if c.is_whitespace() {
            if started {
                words.push(std::mem::take(&mut word));
                started = false;
            }
        } else {
            word.push(c);
            started = true;
        }
    }
    if quote.is_some() {
        bail!("EDITOR 引号未闭合");
    }
    if started {
        words.push(word);
    }
    if words.first().is_none_or(String::is_empty) {
        bail!("请设置 VISUAL 或 EDITOR（例如 code --wait）");
    }
    Ok(words)
}
impl Editor {
    pub fn start(text: &str) -> Result<Self> {
        let configured = std::env::var("VISUAL")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .or_else(|| {
                std::env::var("EDITOR")
                    .ok()
                    .filter(|v| !v.trim().is_empty())
            })
            .unwrap_or_else(|| {
                if cfg!(windows) {
                    "notepad.exe".into()
                } else {
                    "vi".into()
                }
            });
        let args = arguments(&configured)?;
        let executable = std::path::Path::new(&args[0])
            .file_name()
            .and_then(|v| v.to_str())
            .unwrap_or("");
        let confirm_return = cfg!(windows)
            && (executable.eq_ignore_ascii_case("notepad")
                || executable.eq_ignore_ascii_case("notepad.exe"));
        let mut file = tempfile::Builder::new()
            .prefix("expert-draft-")
            .suffix(if confirm_return { ".txt" } else { ".md" })
            .tempfile()?;
        file.write_all(text.as_bytes())?;
        file.flush()?;
        // Close our handle before editors open or atomically replace the file.
        let file = file.into_temp_path();
        let child = Command::new(&args[0])
            .args(&args[1..])
            .arg(&file)
            .spawn()
            .context("无法启动外部编辑器；GUI 编辑器需要配置等待参数，如 code --wait")?;
        Ok(Self {
            child,
            file: Some(file),
            confirm_return,
            confirmed: false,
        })
    }
    pub fn needs_confirmation(&self) -> bool {
        self.confirm_return && !self.confirmed
    }
    pub fn confirm(&mut self) {
        self.confirmed = true;
    }
    pub fn path(&self) -> Option<&std::path::Path> {
        self.file.as_deref()
    }
    pub fn poll(&mut self) -> Result<Option<String>> {
        let status = self.child.try_wait()?;
        let failed = status.is_some_and(|s| !s.success());
        if !failed && (self.needs_confirmation() || (!self.confirm_return && status.is_none())) {
            return Ok(None);
        }
        let file = self.file.take().context("编辑会话已经结束")?;
        let result = (|| {
            if failed {
                bail!("外部编辑器退出失败");
            }
            if std::fs::metadata(&file)?.len() > 1024 * 1024 {
                bail!("草稿超过 1 MiB 上限");
            }
            let text = std::fs::read_to_string(&file).context("草稿须使用 UTF-8 编码")?;
            Ok(text.trim_start_matches('\u{feff}').replace("\r\n", "\n"))
        })();
        match result {
            Ok(text) => {
                // Notepad can hand the file to another process. Keep it even if
                // the user returns before closing that window.
                if self.confirm_return {
                    file.keep().context("无法保留编辑器草稿")?;
                }
                Ok(Some(text))
            }
            Err(error) => {
                let path = file.keep()?;
                bail!("{error}；编辑内容保留在 {}", path.display());
            }
        }
    }
}
