use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub fn mime(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "avif" => "image/avif",
        "tif" | "tiff" => "image/tiff",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "opus" => "audio/opus",
        "weba" => "audio/webm",
        "amr" => "audio/amr",
        "pdf" => "application/pdf",
        "json" => "application/json",
        "csv" => "text/csv",
        "txt" | "md" | "rs" | "py" | "dart" | "c" | "h" | "js" | "ts" | "log" => "text/plain",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        _ => "application/octet-stream",
    }
}
pub fn import_params(path: &Path) -> Result<Value> {
    let path = path.canonicalize()?;
    ensure!(path.is_file(), "请选择文件，不能附加目录");
    Ok(json!({"path":path.to_string_lossy(),"confirmed":true}))
}
pub fn paths(text: &str) -> Option<Vec<PathBuf>> {
    let text = text.trim();
    // A single unquoted Windows path can itself contain spaces.
    let whole = PathBuf::from(text);
    if whole.is_absolute() && whole.is_file() {
        return Some(vec![whole]);
    }
    let text = text
        .strip_prefix("& ")
        .filter(|s| s.starts_with(['\'', '"']))
        .unwrap_or(text);
    let mut result = vec![];
    let mut token = String::new();
    let mut quote = None;
    for c in text.trim().chars() {
        match c {
            '\'' | '"' if quote == Some(c) => quote = None,
            '\'' | '"' if quote.is_none() && token.is_empty() => quote = Some(c),
            c if c.is_whitespace() && quote.is_none() => {
                if !token.is_empty() {
                    result.push(PathBuf::from(std::mem::take(&mut token)));
                }
            }
            _ => token.push(c),
        }
    }
    if quote.is_some() {
        return None;
    }
    if !token.is_empty() {
        result.push(PathBuf::from(token));
    }
    if result.is_empty() || result.iter().any(|p| !p.is_file()) {
        return None;
    }
    Some(result)
}

/// Windows Terminal may translate clipboard text into ordinary character keys.
/// Collect only contiguous insertions, and replace a completed, existing absolute
/// file path, leaving surrounding prose and other editors untouched.
#[derive(Default)]
pub struct NativePathPaste {
    start: usize,
    value: String,
    session: String,
    at: Option<std::time::Instant>,
}
impl NativePathPaste {
    pub fn track(
        &mut self,
        app: &crate::app::App,
        before: usize,
        old_len: usize,
        c: char,
        now: std::time::Instant,
    ) {
        if app.form.is_some()
            || app.drawer.is_some()
            || app.view != crate::app::View::Chat
            || app.input.len() != old_len + c.len_utf8()
            || app.cursor != before + c.len_utf8()
            || app.input.get(before..app.cursor) != Some(c.to_string().as_str())
        {
            self.clear();
            return;
        }
        let session = app.session_id().unwrap_or("");
        if self
            .at
            .is_none_or(|t| now.duration_since(t) > std::time::Duration::from_millis(80))
            || self.start + self.value.len() != before
            || self.session != session
        {
            self.start = before;
            self.value.clear();
            self.session = session.into();
        }
        self.value.push(c);
        self.at = Some(now);
    }
    pub fn clear(&mut self) {
        self.at = None;
        self.value.clear();
    }
    pub fn buffering(&self) -> bool {
        self.at.is_some()
    }
    pub fn ready(&self) -> bool {
        self.at
            .is_some_and(|t| t.elapsed() >= std::time::Duration::from_millis(24))
    }
    pub fn finish(&mut self, app: &mut crate::app::App) -> bool {
        if self.value.is_empty() {
            return false;
        }
        let value = std::mem::take(&mut self.value);
        self.at = None;
        if app.form.is_some()
            || app.drawer.is_some()
            || app.view != crate::app::View::Chat
            || self.session != app.session_id().unwrap_or("")
            || app.input.get(self.start..self.start + value.len()) != Some(value.as_str())
        {
            return false;
        }
        let trimmed = value.trim_start_matches(['\'', '"', ' ', '&']);
        if !Path::new(trimmed).is_absolute() {
            return false;
        }
        let Some(paths) = paths(&value) else {
            return false;
        };
        if paths.iter().any(|p| !p.is_absolute()) {
            return false;
        }
        let end = self.start + value.len();
        app.input.drain(self.start..end);
        app.cursor = if app.cursor >= end {
            app.cursor - value.len()
        } else {
            app.cursor.min(self.start)
        };
        app.paste_collapsed = false;
        let commands = app.import_paths(paths);
        app.outbox.extend(commands);
        true
    }
}
