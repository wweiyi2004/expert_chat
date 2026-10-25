use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::{
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};

#[derive(Default, Debug, Clone)]
pub struct LauncherOptions {
    pub gui: Option<PathBuf>,
    pub auto_start: bool,
}
#[derive(Clone, Deserialize)]
pub struct Discovery {
    pub v: u32,
    pub pid: u32,
    pub port: u16,
    pub token: String,
}
impl std::fmt::Debug for Discovery {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Discovery")
            .field("v", &self.v)
            .field("pid", &self.pid)
            .field("port", &self.port)
            .field("token", &"[redacted]")
            .finish()
    }
}
pub fn discovery_path() -> Result<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .context("LOCALAPPDATA is unavailable; use --demo or start the desktop GUI")?;
    Ok(PathBuf::from(base).join("expert-chat/tui/bridge.json"))
}
pub fn read_discovery(path: &Path) -> Result<Discovery> {
    let meta = std::fs::symlink_metadata(path).context(
        "Bridge discovery missing; start the desktop GUI with --tui-bridge --background",
    )?;
    if meta.file_type().is_symlink() || !meta.is_file() || meta.len() > 8192 {
        bail!("Unsafe bridge discovery file");
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        for target in [
            Some(path),
            path.parent(),
            path.parent().and_then(Path::parent),
        ]
        .into_iter()
        .flatten()
        {
            if std::fs::symlink_metadata(target)?.file_attributes() & 0x400 != 0 {
                bail!("Bridge discovery cannot use a reparse point");
            }
        }
        let mut verifier = Command::new("powershell.exe");
        use std::os::windows::process::CommandExt;
        verifier.creation_flags(0x08000000);
        verifier.env_remove("PSModulePath");
        let output = verifier.args(["-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; $me=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value; foreach($p in @($env:EXPERT_DISCOVERY_CHECK,(Split-Path -LiteralPath $env:EXPERT_DISCOVERY_CHECK))){ $acl=Get-Acl -LiteralPath $p; $owner=([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value; if($owner -notin @($me,'S-1-5-18')){exit 3}; foreach($r in $acl.Access){ if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -notin @($me,'S-1-5-18')){exit 2} } }; exit 0"]).env("EXPERT_DISCOVERY_CHECK", path).output().context("Cannot verify bridge discovery permissions")?;
        if !output.status.success() {
            bail!(
                "Bridge discovery permissions are unsafe; restart an updated desktop GUI to recreate its private discovery file"
            );
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if meta.permissions().mode() & 0o077 != 0 {
            bail!("Bridge discovery must be private (0600)");
        }
    }
    let d: Discovery =
        serde_json::from_slice(&std::fs::read(path)?).context("Invalid bridge discovery")?;
    if d.v != 1 || d.port == 0 || d.pid == 0 || d.token.len() < 32 || d.token.len() > 512 {
        bail!("Unsupported or invalid bridge discovery; update/restart the desktop GUI");
    }
    Ok(d)
}
fn gui_path(options: &LauncherOptions) -> Result<PathBuf> {
    let candidate = options
        .gui
        .clone()
        .or_else(|| std::env::var_os("EXPERT_CHAT_GUI").map(PathBuf::from))
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|p| p.join("expert_chat.exe")))
        });
    let p = candidate.context(
        "Desktop GUI not found; supply --gui <absolute expert_chat.exe path> or EXPERT_CHAT_GUI",
    )?;
    if !p.is_absolute() || !p.is_file() {
        bail!(
            "Desktop GUI not found; supply --gui <absolute expert_chat.exe path> or EXPERT_CHAT_GUI"
        );
    }
    Ok(p)
}
pub fn ensure_bridge(options: &LauncherOptions) -> Result<PathBuf> {
    let path = discovery_path()?;
    if read_discovery(&path).is_ok_and(|d| {
        std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], d.port)),
            Duration::from_millis(250),
        )
        .is_ok()
    }) {
        return Ok(path);
    }
    if !options.auto_start {
        bail!(
            "Bridge unavailable; start the GUI with --tui-bridge --background, or use --gui <path>"
        );
    }
    let gui = gui_path(options)?;
    let mut command = Command::new(gui);
    command.args(["--tui-bridge", "--background"]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .context("Cannot start desktop GUI")?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if read_discovery(&path).is_ok_and(|d| {
            std::net::TcpStream::connect_timeout(
                &std::net::SocketAddr::from(([127, 0, 0, 1], d.port)),
                Duration::from_millis(100),
            )
            .is_ok()
        }) {
            return Ok(path);
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    bail!(
        "GUI did not enable the TUI bridge within 20 seconds. Update the desktop GUI and start it with --tui-bridge --background"
    )
}
