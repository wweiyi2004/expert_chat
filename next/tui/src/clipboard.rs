use anyhow::Result;
use serde_json::Value;
#[derive(Debug)]
pub enum ClipboardData {
    ImageFile(tempfile::TempPath),
    Files(Vec<std::path::PathBuf>),
    Text(String),
}
#[cfg(windows)]
fn run(script: &str, image_path: Option<&std::path::Path>) -> Result<Vec<u8>> {
    use std::os::windows::process::CommandExt;
    let mut command = std::process::Command::new("powershell.exe");
    command
        .args(["-NoProfile", "-NonInteractive", "-Sta", "-Command", script])
        .env_remove("PSModulePath")
        .creation_flags(0x08000000);
    if let Some(path) = image_path {
        command.env("EXPERT_TUI_CLIPBOARD_PNG", path);
    } else {
        command.env_remove("EXPERT_TUI_CLIPBOARD_PNG");
    }
    let output = command.output()?;
    anyhow::ensure!(
        output.status.success(),
        "无法读取剪贴板或选择文件，请使用 /attach 完整文件路径"
    );
    anyhow::ensure!(
        output.stdout.len() < 800_000,
        "剪贴板内容过大，请先保存为文件再 /attach"
    );
    Ok(output.stdout)
}
pub fn read() -> Result<ClipboardData> {
    #[cfg(windows)]
    {
        if let Ok(Some(value)) = native::read() {
            return Ok(value);
        }
        let temporary = tempfile::Builder::new()
            .prefix("expert-clipboard-")
            .suffix(".png")
            .tempfile()?
            .into_temp_path();
        let data = run(
            r#"$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);Add-Type -AssemblyName System.Windows.Forms;if([System.Windows.Forms.Clipboard]::ContainsFileDropList()){@{kind='files';paths=@([System.Windows.Forms.Clipboard]::GetFileDropList())}|ConvertTo-Json -Compress;exit};if([System.Windows.Forms.Clipboard]::ContainsImage()){$img=[System.Windows.Forms.Clipboard]::GetImage();$stream=New-Object System.IO.MemoryStream;try{$img.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png);if($stream.Length -gt 5242880){@{kind='error';message='剪贴板图片超过5 MiB，请先缩小图片'}|ConvertTo-Json -Compress;exit};[System.IO.File]::WriteAllBytes($env:EXPERT_TUI_CLIPBOARD_PNG,$stream.ToArray());@{kind='image_file'}|ConvertTo-Json -Compress}finally{$stream.Dispose();$img.Dispose()};exit};if([System.Windows.Forms.Clipboard]::ContainsText()){@{kind='text';text=[System.Windows.Forms.Clipboard]::GetText()}|ConvertTo-Json -Compress;exit};throw 'Clipboard is empty'"#,
            Some(temporary.as_ref()),
        )?;
        let value: Value = serde_json::from_slice(&data)?;
        match value["kind"].as_str() {
            Some("files") => Ok(ClipboardData::Files(
                value["paths"]
                    .as_array()
                    .map(|v| {
                        v.iter()
                            .filter_map(Value::as_str)
                            .map(std::path::PathBuf::from)
                            .collect()
                    })
                    .unwrap_or_default(),
            )),
            Some("image_file") => {
                anyhow::ensure!(
                    temporary.metadata()?.len() <= 5 * 1024 * 1024,
                    "剪贴板图片超过5 MiB"
                );
                Ok(ClipboardData::ImageFile(temporary))
            }
            Some("error") => anyhow::bail!(
                "{}",
                value["message"].as_str().unwrap_or("无法读取剪贴板图片")
            ),
            Some("text") => Ok(ClipboardData::Text(
                value["text"].as_str().unwrap_or("").into(),
            )),
            _ => anyhow::bail!("剪贴板没有可用内容"),
        }
    }
    #[cfg(not(windows))]
    {
        anyhow::bail!("请使用终端粘贴快捷键，或 /attach 文件路径")
    }
}

#[cfg(windows)]
mod native {
    use super::ClipboardData;
    use anyhow::Result;
    use std::{ffi::c_void, ptr};
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenClipboard(owner: *mut c_void) -> i32;
        fn CloseClipboard() -> i32;
        fn GetClipboardData(format: u32) -> *mut c_void;
        fn IsClipboardFormatAvailable(format: u32) -> i32;
        fn RegisterClipboardFormatW(name: *const u16) -> u32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalLock(handle: *mut c_void) -> *mut c_void;
        fn GlobalUnlock(handle: *mut c_void) -> i32;
        fn GlobalSize(handle: *mut c_void) -> usize;
    }
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn DragQueryFileW(drop: *mut c_void, index: u32, path: *mut u16, size: u32) -> u32;
    }
    struct Clipboard;
    impl Drop for Clipboard {
        fn drop(&mut self) {
            unsafe {
                CloseClipboard();
            }
        }
    }
    fn bytes(format: u32, limit: usize) -> Option<Vec<u8>> {
        unsafe {
            let handle = GetClipboardData(format);
            if handle.is_null() {
                return None;
            }
            let size = GlobalSize(handle);
            if size == 0 || size > limit {
                return None;
            }
            let pointer = GlobalLock(handle);
            if pointer.is_null() {
                return None;
            }
            let result = std::slice::from_raw_parts(pointer.cast::<u8>(), size).to_vec();
            GlobalUnlock(handle);
            Some(result)
        }
    }
    fn image_file(data: &[u8], extension: &str) -> Result<ClipboardData> {
        use std::io::Write;
        let mut file = tempfile::Builder::new()
            .prefix("expert-clipboard-")
            .suffix(extension)
            .tempfile()?;
        file.write_all(data)?;
        Ok(ClipboardData::ImageFile(file.into_temp_path()))
    }
    pub fn read() -> Result<Option<ClipboardData>> {
        unsafe {
            if OpenClipboard(ptr::null_mut()) == 0 {
                return Ok(None);
            }
            let _clipboard = Clipboard;
            if IsClipboardFormatAvailable(15) != 0 {
                let drop = GetClipboardData(15);
                if drop.is_null() {
                    return Ok(None);
                }
                let count = DragQueryFileW(drop, u32::MAX, ptr::null_mut(), 0);
                anyhow::ensure!(count <= 4096, "剪贴板文件数量过多");
                let mut paths = Vec::new();
                for index in 0..count {
                    let length = DragQueryFileW(drop, index, ptr::null_mut(), 0);
                    if length == 0 || length > 32768 {
                        continue;
                    }
                    let mut path = vec![0u16; length as usize + 1];
                    let copied = DragQueryFileW(drop, index, path.as_mut_ptr(), length + 1);
                    if copied > 0 {
                        paths.push(std::path::PathBuf::from(String::from_utf16_lossy(
                            &path[..copied as usize],
                        )));
                    }
                }
                return Ok(Some(ClipboardData::Files(paths)));
            }
            for name in ["PNG", "image/png"] {
                let name: Vec<_> = name.encode_utf16().chain(Some(0)).collect();
                let format = RegisterClipboardFormatW(name.as_ptr());
                if format != 0
                    && IsClipboardFormatAvailable(format) != 0
                    && let Some(data) = bytes(format, 5 * 1024 * 1024)
                    && data.starts_with(b"\x89PNG\r\n\x1a\n")
                {
                    return Ok(Some(image_file(&data, ".png")?));
                }
            }
            // Standard screenshot DIBs can be wrapped as BMP without a PowerShell
            // process or image re-encoding. Unusual/compressed formats use the fallback.
            for format in [17, 8] {
                let Some(data) = bytes(format, 5 * 1024 * 1024 - 14) else {
                    continue;
                };
                if data.len() < 40 {
                    continue;
                }
                let u32at = |at: usize| u32::from_le_bytes(data[at..at + 4].try_into().unwrap());
                let header = u32at(0) as usize;
                if ![40, 108, 124].contains(&header) || data.len() < header {
                    continue;
                }
                let w = u32at(4) as i32;
                let h = u32at(8) as i32;
                let bits = u16::from_le_bytes(data[14..16].try_into().unwrap()) as usize;
                let compression = u32at(16);
                if w <= 0
                    || h == 0
                    || h == i32::MIN
                    || ![24, 32].contains(&bits)
                    || ![0, 3, 6].contains(&compression)
                {
                    continue;
                }
                if header == 124 && (u32at(112) != 0 || u32at(116) != 0) {
                    continue;
                }
                let masks = if header == 40 {
                    match compression {
                        3 => 12,
                        6 => 16,
                        _ => 0,
                    }
                } else {
                    0
                };
                let offset = header + masks + (u32at(32) as usize).saturating_mul(4);
                let needed = (w as usize)
                    .saturating_mul(bits)
                    .div_ceil(32)
                    .saturating_mul(4)
                    .saturating_mul(h.unsigned_abs() as usize);
                if offset.saturating_add(needed) > data.len() {
                    continue;
                }
                let mut bmp = Vec::with_capacity(data.len() + 14);
                bmp.extend_from_slice(b"BM");
                bmp.extend_from_slice(&((data.len() + 14) as u32).to_le_bytes());
                bmp.extend_from_slice(&[0; 4]);
                bmp.extend_from_slice(&((offset + 14) as u32).to_le_bytes());
                bmp.extend(data);
                return Ok(Some(image_file(&bmp, ".bmp")?));
            }
            if [2, 8, 17]
                .iter()
                .any(|format| IsClipboardFormatAvailable(*format) != 0)
            {
                return Ok(None);
            }
            if let Some(data) = bytes(13, 800000) {
                let words: Vec<u16> = data
                    .chunks_exact(2)
                    .map(|b| u16::from_le_bytes([b[0], b[1]]))
                    .take_while(|c| *c != 0)
                    .collect();
                return Ok(Some(ClipboardData::Text(String::from_utf16_lossy(&words))));
            }
            Ok(None)
        }
    }
}
pub fn read_image() -> Result<tempfile::TempPath> {
    match read()? {
        ClipboardData::ImageFile(path) => Ok(path),
        _ => anyhow::bail!("剪贴板没有图片；文件可使用 /attach"),
    }
}
pub fn select_files() -> Result<ClipboardData> {
    #[cfg(windows)]
    {
        let data = run(
            r#"$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);Add-Type -AssemblyName System.Windows.Forms;$dialog=New-Object System.Windows.Forms.OpenFileDialog;$dialog.Title='添加附件';$dialog.Multiselect=$true;$dialog.Filter='所有文件 (*.*)|*.*';try{if($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){@{paths=@($dialog.FileNames)}|ConvertTo-Json -Compress}else{@{paths=@()}|ConvertTo-Json -Compress}}finally{$dialog.Dispose()}"#,
            None,
        )?;
        let value: Value = serde_json::from_slice(&data)?;
        Ok(ClipboardData::Files(
            value["paths"]
                .as_array()
                .map(|v| {
                    v.iter()
                        .filter_map(Value::as_str)
                        .map(std::path::PathBuf::from)
                        .collect()
                })
                .unwrap_or_default(),
        ))
    }
    #[cfg(not(windows))]
    {
        anyhow::bail!("此终端没有系统文件选择器；请使用 /attach 文件路径")
    }
}
/// Called only after an explicit copy action; no clipboard reads are performed.
pub fn write_text(text: &str) -> Result<()> {
    #[cfg(windows)]
    {
        use std::io::Write;
        use std::os::windows::process::CommandExt;
        use std::process::Stdio;
        let script = r#"$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Windows.Forms;$reader=New-Object System.IO.StreamReader([Console]::OpenStandardInput(),[System.Text.UTF8Encoding]::new($false));try{$text=$reader.ReadToEnd();[System.Windows.Forms.Clipboard]::SetText($text)}finally{$reader.Dispose()}"#;
        let mut child = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Sta", "-Command", script])
            .env_remove("PSModulePath")
            .creation_flags(0x08000000)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        if let Some(mut input) = child.stdin.take() {
            input.write_all(text.as_bytes())?;
        }
        anyhow::ensure!(
            child.wait()?.success(),
            "无法写入系统剪贴板；可按住 Shift 使用终端原生选取复制"
        );
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = text;
        anyhow::bail!("当前平台未配置系统剪贴板；请按住 Shift 选取后使用终端复制")
    }
}
