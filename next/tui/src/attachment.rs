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
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
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
    let mut result = vec![];
    let mut token = String::new();
    let mut quoted = false;
    for c in text.trim().chars() {
        match c {
            '"' => quoted = !quoted,
            c if c.is_whitespace() && !quoted => {
                if !token.is_empty() {
                    result.push(PathBuf::from(std::mem::take(&mut token)));
                }
            }
            _ => token.push(c),
        }
    }
    if quoted {
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
