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
    if let Some(directory) = std::env::var_os("EXPERT_HOST_DISCOVERY") {
        let path = PathBuf::from(directory);
        if !path.is_absolute() {
            bail!("EXPERT_HOST_DISCOVERY must be absolute");
        }
        return Ok(path.join("bridge.json"));
    }
    if let Some(directory) = std::env::var_os("EXPERT_HOST_DATA_DIR") {
        let path = PathBuf::from(directory);
        if !path.is_absolute() {
            bail!("EXPERT_HOST_DATA_DIR must be absolute");
        }
        return Ok(path.join("host/discovery/bridge.json"));
    }
    let base = std::env::var_os("LOCALAPPDATA")
        .context("LOCALAPPDATA is unavailable; configure EXPERT_HOST_DISCOVERY")?;
    Ok(PathBuf::from(base).join("expert-chat/tui/bridge.json"))
}

pub fn read_discovery(path: &Path) -> Result<Discovery> {
    let meta = std::fs::symlink_metadata(path)
        .context("Host discovery missing; start the bundled expert-host executable")?;
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
fn host_path(options: &LauncherOptions) -> Result<PathBuf> {
    let candidate = std::env::var_os("EXPERT_CHAT_HOST")
        .map(PathBuf::from)
        .or_else(|| {
            options
                .gui
                .as_ref()
                .and_then(|gui| gui.parent().map(|p| p.join("host/bin/expert-host.exe")))
        })
        .or_else(|| {
            std::env::var_os("EXPERT_CHAT_GUI").and_then(|gui| {
                PathBuf::from(gui)
                    .parent()
                    .map(|p| p.join("host/bin/expert-host.exe"))
            })
        })
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|p| p.join("host/bin/expert-host.exe")))
        });
    let p = candidate
        .context("Independent host not found; use the complete bundle or set EXPERT_CHAT_HOST")?;
    if !p.is_absolute() || !p.is_file() {
        bail!("Independent host not found; use the complete bundle or set EXPERT_CHAT_HOST");
    }
    Ok(p)
}
pub(crate) struct ReadyBridge {
    pub path: PathBuf,
    pub discovery: Discovery,
}

pub fn ensure_bridge(options: &LauncherOptions) -> Result<PathBuf> {
    Ok(prepare_bridge(options)?.path)
}

// Hand the validated discovery to the first connection. A reconnect reads and
// validates again, rather than keeping a process-wide permissions cache.
pub(crate) fn prepare_bridge(options: &LauncherOptions) -> Result<ReadyBridge> {
    let path = discovery_path()?;
    if let Ok(d) = read_discovery(&path)
        && std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], d.port)),
            Duration::from_millis(250),
        )
        .is_ok()
    {
        let mut client = crate::headless::HostConnection::from_discovery(&d)?;
        if client.hello["capabilities"].as_array().is_some_and(|v| {
            [
                "terminal.ssh-forward.v1",
                "terminal.steering-status.v1",
                "terminal.workbench.v1",
                "terminal.workbench-files.v2",
                "terminal.shared-agent-prompts.v1",
                "terminal.workbench-receipts.v2",
                "window-lifecycle.v1",
                "terminal.public-fetch.v1",
                "terminal.workspace-permissions.v1",
            ]
            .iter()
            .all(|required| v.iter().any(|c| c == required))
        }) {
            return Ok(ReadyBridge { path, discovery: d });
        }
        if !options.auto_start {
            bail!("Host 版本较旧，请退出旧版 Host 并从完整新发行包重新启动");
        }
        // Verify the replacement exists before requesting a graceful, idle-only upgrade.
        let _ = host_path(options)?;
        client
            .call("host.shutdown", serde_json::json!({"confirmed":true}))
            .context("旧版 Host 仍有活动任务，暂不能升级；完成任务后重新打开 expert")?;
        drop(client);
        let deadline = Instant::now() + Duration::from_secs(20);
        while std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], d.port)),
            Duration::from_millis(100),
        )
        .is_ok()
        {
            if Instant::now() >= deadline {
                bail!("旧版 Host 尚未退出，未强制终止任何任务");
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    if !options.auto_start {
        bail!("Host unavailable; start expert-host or allow automatic host startup");
    }
    let host = host_path(options)?;
    let mut command = Command::new(host);
    if let Some(directory) = std::env::var_os("EXPERT_HOST_DISCOVERY") {
        command.arg("--discovery-dir").arg(directory);
    }
    if let Some(directory) = std::env::var_os("EXPERT_HOST_DATA_DIR") {
        command.arg("--data-dir").arg(directory);
    }
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
        .context("Cannot start independent host")?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Ok(d) = read_discovery(&path)
            && std::net::TcpStream::connect_timeout(
                &std::net::SocketAddr::from(([127, 0, 0, 1], d.port)),
                Duration::from_millis(100),
            )
            .is_ok()
        {
            return Ok(ReadyBridge { path, discovery: d });
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    bail!(
        "Independent host did not become ready within 20 seconds. Check the complete bundle and close any legacy application still owning the data."
    )
}
