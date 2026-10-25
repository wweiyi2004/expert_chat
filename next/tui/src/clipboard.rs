pub fn read_image() -> anyhow::Result<serde_json::Value> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let script = r#"$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Windows.Forms; $img=[System.Windows.Forms.Clipboard]::GetImage(); if($null -eq $img){throw 'No image on clipboard'}; $stream=New-Object System.IO.MemoryStream; try{$img.Save($stream,[System.Drawing.Imaging.ImageFormat]::Png); if($stream.Length -gt 524288){throw 'Clipboard image exceeds 512 KiB; use GUI for larger images'}; @{name='clipboard.png';mime='image/png';data_base64=[Convert]::ToBase64String($stream.ToArray())}|ConvertTo-Json -Compress}finally{$stream.Dispose();$img.Dispose()}"#;
        let output = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Sta", "-Command", script])
            .env_remove("PSModulePath")
            .creation_flags(0x08000000)
            .output()?;
        anyhow::ensure!(
            output.status.success(),
            "剪贴板没有可用图片，或图片过大；请在 GUI 添加附件"
        );
        anyhow::ensure!(
            output.stdout.len() < 750_000,
            "剪贴板图片过大；请在 GUI 添加附件"
        );
        Ok(serde_json::from_slice(&output.stdout)?)
    }
    #[cfg(not(windows))]
    {
        anyhow::bail!("此平台尚未启用图片剪贴板；请在 GUI 添加附件")
    }
}
