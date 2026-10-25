use crate::app::{App, Command};
use crate::launcher::read_discovery;
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    net::{SocketAddr, TcpStream},
    path::PathBuf,
    sync::mpsc::{self, Receiver, SyncSender, TryRecvError},
    thread,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket};

static CLIENT_EPOCH: std::sync::LazyLock<u128> = std::sync::LazyLock::new(|| {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
});
static NEXT_REQUEST: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

#[derive(Debug)]
pub enum SourceEvent {
    Event(Value),
    Snapshot(Value),
    Response { method: String, result: Value },
    Error(String),
    Connection { connected: bool, message: String },
}
pub trait DataSource {
    fn poll(&mut self) -> Vec<SourceEvent>;
    fn send(&mut self, command: Command) -> Result<()>;
}
pub fn fixture_events(name: &str) -> Result<Vec<Value>> {
    let body = match name {
        "accepted" => include_str!("../../../design/tui/fixtures/accepted.jsonl"),
        "agents" => include_str!("../../../design/tui/fixtures/agents.jsonl"),
        "approval" => include_str!("../../../design/tui/fixtures/approval.jsonl"),
        "default_workspace" => include_str!("../../../design/tui/fixtures/default_workspace.jsonl"),
        "failed" => include_str!("../../../design/tui/fixtures/failed.jsonl"),
        "first_run" => include_str!("../../../design/tui/fixtures/first_run.jsonl"),
        "prompt" => include_str!("../../../design/tui/fixtures/prompt.jsonl"),
        "resume" => include_str!("../../../design/tui/fixtures/resume.jsonl"),
        "running" => include_str!("../../../design/tui/fixtures/running.jsonl"),
        "retrying" => include_str!("../../../design/tui/fixtures/retrying.jsonl"),
        "startup_error" => include_str!("../../../design/tui/fixtures/startup_error.jsonl"),
        "stopped" => include_str!("../../../design/tui/fixtures/stopped.jsonl"),
        "waiting_acceptance" => {
            include_str!("../../../design/tui/fixtures/waiting_acceptance.jsonl")
        }
        "welcome" => include_str!("../../../design/tui/fixtures/welcome.jsonl"),
        _ => bail!(
            "Unknown demo {name}; use welcome, first_run, default_workspace, startup_error, prompt, resume, running, approval, retrying, failed, stopped, waiting_acceptance, accepted, agents"
        ),
    };
    body.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| Ok(serde_json::from_str(l)?))
        .collect()
}
pub struct DemoSource {
    app: App,
    events: Vec<SourceEvent>,
    counter: u64,
}
impl DemoSource {
    pub fn new(name: &str) -> Result<Self> {
        let mut app = App::default();
        let mut events = Vec::new();
        for event in fixture_events(name)? {
            app.apply_event(&event)?;
            events.push(SourceEvent::Event(event));
        }
        Ok(Self {
            app,
            events,
            counter: 0,
        })
    }
}
impl DataSource for DemoSource {
    fn poll(&mut self) -> Vec<SourceEvent> {
        std::mem::take(&mut self.events)
    }
    fn send(&mut self, command: Command) -> Result<()> {
        self.counter += 1;
        let p = &command.params;
        let state = &mut self.app.snapshot;
        let result = match command.method.as_str() {
            "snapshot.get" | "session.open" => state.clone(),
            "session.list" => json!({"sessions":state["sessions"]}),
            "models.list" => json!({"models":state["models"]}),
            "workspace.list" => json!({"workspaces":state["workspaces"]}),
            "changes.list" => json!({"changes":state["changes"]}),
            "agents.list" => json!({"agents":state["agents"]}),
            "changes.diff" => state["changes"]
                .as_array()
                .and_then(|a| a.iter().find(|v| v["id"] == p["id"]))
                .cloned()
                .unwrap_or(json!({"diff":[]})),
            "files.list" => json!({"files":[]}),
            "workspace.prepare" => json!({"confirmation_required":true,"path":p["path"]}),
            "workspace.register" => {
                if p["confirmed"] != true {
                    bail!("Demo workspace confirmation required");
                }
                let w = json!({"id":"demo-workspace","name":"demo","path":p["path"],"access":p["access"],"remote":false});
                state["workspaces"] = json!([w.clone()]);
                w
            }
            "session.new" => {
                state["session"] = json!({"id":"demo-session","title":p["title"].as_str().unwrap_or("演示任务"),"status":"idle","mode":"work","permission":"request","round":0,"round_limit":24});
                state["messages"] = json!([]);
                json!({"session_id":"demo-session"})
            }
            "message.send" | "task.revise" => {
                if !state["messages"].is_array() {
                    state["messages"] = json!([]);
                }
                state["messages"].as_array_mut().unwrap().push(json!({"id":format!("demo-user-{}",self.counter),"role":"user","text":p["text"]}));
                state["session"]["status"] = json!("idle");
                json!({"accepted":true})
            }
            "queue.add" => {
                let id = format!("demo-queue-{}", self.counter);
                if !state["queued"].is_array() {
                    state["queued"] = json!([]);
                }
                state["queued"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!({"id":id,"text":p["text"],"status":"queued"}));
                json!({"id":id})
            }
            "queue.remove" => {
                let items = state["queued"]
                    .as_array_mut()
                    .ok_or_else(|| anyhow::anyhow!("No queued items"))?;
                let i = items
                    .iter()
                    .position(|v| v["id"] == p["id"])
                    .ok_or_else(|| anyhow::anyhow!("Queued item unavailable"))?;
                let item = items.remove(i);
                json!({"text":item["text"]})
            }
            "task.stop" => {
                state["session"]["status"] = json!("stopped");
                json!({"accepted":true})
            }
            "task.resume" => {
                state["session"]["status"] = json!("idle");
                json!({"accepted":true})
            }
            "task.accept" => {
                state["session"]["status"] = json!("accepted");
                json!({"accepted":true})
            }
            "approval.decide" => {
                if let Some(a) = state["approvals"].as_array_mut() {
                    a.retain(|v| v["id"] != p["id"]);
                }
                state["session"]["status"] = json!("idle");
                json!({"accepted":true})
            }
            "permission.set" => {
                if p["permission"] == "full" && p["confirmed"] != true {
                    bail!("Full access requires confirmation");
                }
                state["session"]["permission"] = p["permission"].clone();
                json!({"accepted":true})
            }
            "mode.set" => {
                state["session"]["mode"] = p["mode"].clone();
                json!({"accepted":true})
            }
            "model.set" => {
                for key in ["choice", "thinking", "effort"] {
                    state["session"][if key == "choice" { "model_choice" } else { key }] =
                        p[key].clone();
                }
                json!({"accepted":true})
            }
            "workspace.set" => {
                state["session"]["workspace_id"] = p["workspace_id"].clone();
                json!({"accepted":true})
            }
            _ => bail!("{} is unavailable in offline demo", command.method),
        };
        self.events.push(SourceEvent::Response {
            method: command.method,
            result,
        });
        self.events
            .push(SourceEvent::Snapshot(self.app.snapshot.clone()));
        Ok(())
    }
}

pub struct BridgeSource {
    commands: SyncSender<Command>,
    events: Receiver<SourceEvent>,
}
impl BridgeSource {
    /// Resolve/start the trusted GUI entirely off the terminal event thread.
    pub fn launch(options: crate::launcher::LauncherOptions) -> Self {
        let (tx, rx) = mpsc::sync_channel(64);
        let (etx, erx) = mpsc::sync_channel(1024);
        thread::spawn(move || {
            let _ = etx.send(SourceEvent::Connection {
                connected: false,
                message: "Connecting to desktop GUI…".into(),
            });
            match crate::launcher::ensure_bridge(&options) {
                Ok(path) => worker(path, rx, etx),
                Err(error) => {
                    let _ = etx.send(SourceEvent::Error(error.to_string()));
                }
            }
        });
        Self {
            commands: tx,
            events: erx,
        }
    }
    pub fn new(discovery: PathBuf) -> Self {
        let (tx, rx) = mpsc::sync_channel(64);
        let (etx, erx) = mpsc::sync_channel(1024);
        thread::spawn(move || worker(discovery, rx, etx));
        Self {
            commands: tx,
            events: erx,
        }
    }
}
impl DataSource for BridgeSource {
    fn poll(&mut self) -> Vec<SourceEvent> {
        self.events.try_iter().take(256).collect()
    }
    fn send(&mut self, command: Command) -> Result<()> {
        if serde_json::to_vec(&command.params)?.len() + command.method.len() + 128 > 1024 * 1024 {
            bail!("Request exceeds the bridge 1 MiB limit; reduce attachment or message size");
        }
        self.commands
            .try_send(command)
            .map_err(|_| anyhow::anyhow!("Bridge busy/disconnected; command was not sent"))
    }
}
fn write_request(
    ws: &mut WebSocket<TcpStream>,
    counter: &mut u64,
    method: &str,
    params: Value,
    pending: &mut HashMap<String, String>,
) -> Result<()> {
    *counter += 1;
    let id = format!(
        "tui-{}-{}-{}",
        std::process::id(),
        *CLIENT_EPOCH,
        NEXT_REQUEST.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    let encoded = json!({"v":1,"id":id,"method":method,"params":params}).to_string();
    if encoded.len() > 1024 * 1024 {
        bail!("Request exceeds the bridge 1 MiB limit");
    }
    // A failed write can still have reached the peer. Keep it outstanding so a
    // disconnect reports an unknown result rather than implying safe failure.
    pending.insert(id, method.to_owned());
    ws.send(Message::Text(encoded.into()))?;
    Ok(())
}
fn connect(
    path: &std::path::Path,
    counter: &mut u64,
    pending: &mut HashMap<String, String>,
) -> Result<WebSocket<TcpStream>> {
    let d = read_discovery(path)?;
    let stream = TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], d.port)),
        Duration::from_secs(2),
    )?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let config = tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(8 * 1024 * 1024))
        .max_frame_size(Some(8 * 1024 * 1024));
    let (mut ws, _) = tungstenite::client::client_with_config(
        format!("ws://127.0.0.1:{}/tui", d.port),
        stream,
        Some(config),
    )
    .map_err(|_| anyhow::anyhow!("Bridge WebSocket handshake failed; update desktop GUI"))?;
    write_request(
        &mut ws,
        counter,
        "hello",
        json!({"protocol":1,"token":d.token,"client_id":format!("expert-tui-{}-{}",std::process::id(),*CLIENT_EPOCH)}),
        pending,
    )?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| anyhow::anyhow!("Bridge hello timed out"))?;
        ws.get_mut().set_read_timeout(Some(remaining))?;
        match ws.read()? {
            Message::Text(t) => {
                let value: Value = serde_json::from_str(&t)?;
                if value["id"]
                    .as_str()
                    .is_some_and(|id| pending.remove(id).is_some())
                {
                    if value["v"] != 1 || value["ok"] != true || value["result"]["protocol"] != 1 {
                        bail!(
                            "Bridge authentication/version rejected; restart an updated desktop GUI"
                        );
                    }
                    break;
                }
            }
            Message::Ping(p) => ws.send(Message::Pong(p))?,
            _ => {}
        }
    }
    ws.get_mut()
        .set_read_timeout(Some(Duration::from_millis(100)))?;
    Ok(ws)
}
fn worker(path: PathBuf, commands: Receiver<Command>, events: SyncSender<SourceEvent>) {
    let mut counter = 0;
    let mut session: Option<String> = None;
    let mut pending = HashMap::new();
    loop {
        pending.clear();
        let mut ws = match connect(&path, &mut counter, &mut pending) {
            Ok(ws) => ws,
            Err(_) => {
                if events.send(SourceEvent::Connection{connected:false,message:"Bridge unavailable or authentication rejected. Start/update GUI with --tui-bridge --background; reconnecting…".into()}).is_err(){return;}
                for _ in 0..10 {
                    match commands.try_recv() {
                        Ok(_) => {
                            let _ = events.send(SourceEvent::Error(
                                "Disconnected: command not sent; retry after reconnect".into(),
                            ));
                        }
                        Err(TryRecvError::Disconnected) => return,
                        Err(TryRecvError::Empty) => {}
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                continue;
            }
        };
        if events
            .send(SourceEvent::Connection {
                connected: true,
                message: "Connected to local desktop bridge".into(),
            })
            .is_err()
        {
            return;
        }
        let initial = if let Some(s) = &session {
            write_request(
                &mut ws,
                &mut counter,
                "session.open",
                json!({"session_id":s}),
                &mut pending,
            )
        } else {
            write_request(
                &mut ws,
                &mut counter,
                "snapshot.get",
                json!({}),
                &mut pending,
            )
        };
        if initial.is_err() {
            continue;
        }
        let mut seq = 0;
        let mut heartbeat = Instant::now();
        let mut received = Instant::now();
        let reason: Result<()> = (|| loop {
            match commands.try_recv() {
                Ok(command) => {
                    write_request(
                        &mut ws,
                        &mut counter,
                        &command.method,
                        command.params,
                        &mut pending,
                    )?;
                }
                Err(TryRecvError::Disconnected) => {
                    let _ = ws.close(None);
                    return Ok(());
                }
                Err(TryRecvError::Empty) => {}
            }
            if heartbeat.elapsed() >= Duration::from_secs(15) {
                write_request(&mut ws, &mut counter, "ping", json!({}), &mut pending)?;
                heartbeat = Instant::now();
            }
            if received.elapsed() > Duration::from_secs(45) {
                bail!("Bridge heartbeat expired");
            }
            match ws.read() {
                Ok(Message::Text(t)) => {
                    received = Instant::now();
                    if t.len() > 8 * 1024 * 1024 {
                        bail!("Bridge message exceeds limit");
                    }
                    let value: Value = serde_json::from_str(&t)?;
                    if value["v"] != 1 {
                        bail!("Bridge protocol changed");
                    }
                    if value["type"] == "event" {
                        let next = value["seq"].as_u64().unwrap_or(0);
                        if next <= seq {
                            continue;
                        }
                        seq = next;
                        if value["event"] == "snapshot" {
                            session = value["data"]["session"]["id"].as_str().map(str::to_owned);
                        }
                        events.send(SourceEvent::Event(value))?;
                    } else if let Some(method) =
                        value["id"].as_str().and_then(|id| pending.remove(id))
                    {
                        if value["ok"] == true {
                            let result = value["result"].clone();
                            if method == "session.new" {
                                session = result["session_id"].as_str().map(str::to_owned);
                                if let Some(s) = &session {
                                    write_request(
                                        &mut ws,
                                        &mut counter,
                                        "session.open",
                                        json!({"session_id":s}),
                                        &mut pending,
                                    )?;
                                }
                            }
                            if method == "snapshot.get" || method == "session.open" {
                                session = result["session"]["id"].as_str().map(str::to_owned);
                                events.send(SourceEvent::Snapshot(result.clone()))?;
                            }
                            if method != "ping" {
                                events.send(SourceEvent::Response {
                                    method: method.clone(),
                                    result,
                                })?;
                                if ![
                                    "snapshot.get",
                                    "session.open",
                                    "session.list",
                                    "workspace.prepare",
                                    "workspace.list",
                                    "models.list",
                                    "changes.list",
                                    "changes.diff",
                                    "agents.list",
                                    "files.list",
                                ]
                                .contains(&method.as_str())
                                {
                                    write_request(
                                        &mut ws,
                                        &mut counter,
                                        "snapshot.get",
                                        json!({"session_id":session}),
                                        &mut pending,
                                    )?;
                                }
                            }
                        } else {
                            let code = value["error"]["code"].as_str().unwrap_or("request_failed");
                            let message: String = value["error"]["message"]
                                .as_str()
                                .unwrap_or("Operation rejected")
                                .chars()
                                .filter(|c| !c.is_control())
                                .take(1024)
                                .collect();
                            events
                                .send(SourceEvent::Error(format!("{method}: {code}: {message}")))?;
                        }
                    }
                }
                Ok(Message::Ping(p)) => {
                    ws.send(Message::Pong(p))?;
                }
                Ok(Message::Close(_)) => bail!("Bridge closed"),
                Ok(_) => {}
                Err(tungstenite::Error::Io(e))
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) => return Err(e.into()),
            }
        })();
        if reason.is_ok() {
            return;
        }
        if !pending.is_empty() {
            if events.send(SourceEvent::Error("Connection lost: outstanding request results are unknown. Commands were not replayed; inspect refreshed state before retrying.".into())).is_err(){return;}
            pending.clear();
        }
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;
    use std::net::TcpListener;
    #[test]
    fn request_ids_are_unique_and_mutations_are_never_implicitly_repeated() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            let mut ws = tungstenite::accept(tcp).unwrap();
            let first: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            let second: Value =
                serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_ne!(first["id"], second["id"]);
            assert_eq!(first["method"], "message.send");
            assert_eq!(second["method"], "snapshot.get");
        });
        let tcp = TcpStream::connect(address).unwrap();
        let (mut ws, _) = tungstenite::client(format!("ws://{address}/tui"), tcp).unwrap();
        let mut pending = HashMap::new();
        let mut counter = 0;
        write_request(
            &mut ws,
            &mut counter,
            "message.send",
            json!({"session_id":"s","text":"test"}),
            &mut pending,
        )
        .unwrap();
        write_request(
            &mut ws,
            &mut counter,
            "snapshot.get",
            json!({"session_id":"s"}),
            &mut pending,
        )
        .unwrap();
        assert_eq!(pending.len(), 2);
        server.join().unwrap();
    }
}
