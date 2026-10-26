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
        return match value["kind"].as_str() {
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
        };
    }
    #[cfg(not(windows))]
    {
        anyhow::bail!("请使用终端粘贴快捷键，或 /attach 文件路径")
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
