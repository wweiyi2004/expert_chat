use crate::{
    app::{items, text},
    launcher::{Discovery, LauncherOptions, read_discovery},
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    net::{SocketAddr, TcpStream},
    path::Path,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket};
pub struct HostConnection {
    ws: WebSocket<TcpStream>,
    next: u64,
    prefix: String,
    pub hello: Value,
    window_scoped: bool,
}
impl HostConnection {
    pub fn connect(path: &Path) -> Result<Self> {
        let d = read_discovery(path)?;
        Self::from_discovery(&d)
    }

    pub(crate) fn from_discovery(d: &Discovery) -> Result<Self> {
        Self::from_discovery_with_window(d, false)
    }

    fn from_discovery_with_window(d: &Discovery, window_scoped: bool) -> Result<Self> {
        let stream = TcpStream::connect_timeout(
            &SocketAddr::from(([127, 0, 0, 1], d.port)),
            Duration::from_secs(3),
        )?;
        stream.set_read_timeout(Some(Duration::from_secs(15)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let (ws, _) = tungstenite::client(format!("ws://127.0.0.1:{}/tui", d.port), stream)?;
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        let mut result = Self {
            ws,
            next: 0,
            prefix: format!("cli-{}-{epoch}", std::process::id()),
            hello: Value::Null,
            window_scoped,
        };
        result.hello = result.call(
            "hello",
            json!({"protocol":1,"token":d.token,"client_id":result.prefix,
                "features":if window_scoped {vec!["window-lifecycle.v1"]} else {vec![]}}),
        )?;
        anyhow::ensure!(
            result.hello["execution_host"] == "dart",
            "需要独立 Dart Host，请使用完整发行包"
        );
        Ok(result)
    }
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next += 1;
        let id = format!("{}-{}", self.prefix, self.next);
        let encoded = json!({"v":1,"id":id,"method":method,"params":params}).to_string();
        anyhow::ensure!(encoded.len() <= 1024 * 1024, "请求超过 1 MiB");
        self.ws.send(Message::Text(encoded.into()))?;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            anyhow::ensure!(
                Instant::now() < deadline,
                "{method} 等待回执超时，未自动重放请求"
            );
            match self.ws.read()? {
                Message::Text(t) => {
                    let v: Value = serde_json::from_str(&t)?;
                    if v["id"] == id {
                        if v["ok"] != true {
                            bail!("{method}: {}", text(&v["error"], "message"));
                        }
                        return Ok(v["result"].clone());
                    }
                }
                Message::Ping(v) => self.ws.send(Message::Pong(v))?,
                Message::Close(_) => bail!("Host 连接关闭，操作结果可能未知"),
                _ => {}
            }
        }
    }
}
impl Drop for HostConnection {
    fn drop(&mut self) {
        if self.window_scoped {
            let _ = self
                .ws
                .get_mut()
                .set_read_timeout(Some(Duration::from_secs(3)));
            let _ = self.call("window.close", json!({}));
        }
    }
}
pub fn run(
    options: &LauncherOptions,
    prompt: &str,
    workspace: &Path,
    access: Option<&str>,
    model: Option<&str>,
    format: &str,
    timeout: u64,
) -> Result<()> {
    let bridge = crate::launcher::prepare_bridge(options)?;
    let mut host = HostConnection::from_discovery_with_window(&bridge.discovery, true)?;
    let root = workspace.canonicalize().context("工作区目录不存在")?;
    let mut prepared = host.call("workspace.prepare", json!({"path":root}))?;
    if prepared["confirmation_required"] == true {
        let access=access.context("工作区尚未授权：先在 expert 中选择权限，或显式指定 --allow-workspace read-only/read-write")?;
        prepared = host.call(
            "workspace.register",
            json!({"path":root,"access":access,"confirmed":true}),
        )?;
    }
    let created = host.call(
        "session.new",
        json!({"workspace_id":prepared["workspace"]["id"]}),
    )?;
    let id = text(&created, "session_id");
    anyhow::ensure!(!id.is_empty(), "Host 未返回 session_id");
    eprintln!("Session {id} · expert resume {id}");
    if let Some(model) = model {
        host.call("model.set", json!({"session_id":id,"choice":model}))?;
    }
    host.call("message.send", json!({"session_id":id,"text":prompt}))?;
    let deadline = Instant::now() + Duration::from_secs(timeout.max(1));
    loop {
        anyhow::ensure!(
            Instant::now() < deadline,
            "等待超时；任务可能仍在后台运行，使用 expert resume {id} 查看"
        );
        let snapshot = host.call("snapshot.get", json!({"session_id":id}))?;
        let status = text(&snapshot["session"], "status");
        if status == "approval" || !items(&snapshot, "questions").is_empty() {
            bail!("任务等待交互，使用 expert resume {id} 处理；没有自动批准工具操作");
        }
        let messages = items(&snapshot, "messages");
        let answer = messages
            .iter()
            .rev()
            .find(|m| text(m, "role") == "assistant")
            .map(|m| text(m, "text"))
            .unwrap_or("");
        if !["running", "retrying", "approval"].contains(&status)
            && (messages.iter().any(|m| text(m, "role") == "user")
                || !text(&snapshot["session"], "error").is_empty())
        {
            if format == "json" {
                println!(
                    "{}",
                    json!({"session_id":id,"status":status,"text":answer,"usage":snapshot["session"]["usage"],"error":snapshot["session"]["error"]})
                );
            } else if !answer.is_empty() {
                println!("{answer}");
            }
            anyhow::ensure!(
                text(&snapshot["session"], "error").is_empty(),
                "{}",
                text(&snapshot["session"], "error")
            );
            anyhow::ensure!(
                status != "failed" && status != "stopped",
                "任务状态：{status}，可 expert resume {id} 查看"
            );
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}
