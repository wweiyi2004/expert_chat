use expert_tui::{
    app::Command,
    launcher::read_discovery,
    source::{DataSource, DemoSource, SourceEvent, fixture_events},
};
use serde_json::json;
#[test]
fn every_fixture_replays_through_the_shared_reducer() {
    for name in [
        "accepted",
        "agents",
        "approval",
        "default_workspace",
        "failed",
        "first_run",
        "prompt",
        "resume",
        "running",
        "retrying",
        "startup_error",
        "stopped",
        "waiting_acceptance",
        "welcome",
    ] {
        let envelopes = fixture_events(name).unwrap();
        assert!(!envelopes.is_empty());
        let mut demo = DemoSource::new(name).unwrap();
        let events = demo.poll();
        assert_eq!(events.len(), envelopes.len());
        assert!(demo.poll().is_empty());
        assert!(events.iter().all(|e| matches!(e, SourceEvent::Event(_))));
    }
}
#[test]
fn demo_mutation_is_local_and_requires_confirmation() {
    let mut demo = DemoSource::new("running").unwrap();
    demo.poll();
    assert!(
        demo.send(Command {
            method: "permission.set".into(),
            params: json!({"permission":"full"})
        })
        .is_err()
    );
    demo.send(Command {
        method: "task.stop".into(),
        params: json!({"session_id":"fixture-task"}),
    })
    .unwrap();
    assert!(
        demo.poll()
            .iter()
            .any(|e| matches!(e,SourceEvent::Snapshot(v) if v["session"]["status"]=="stopped"))
    );
}
#[test]
fn discovery_rejects_invalid_and_redacts_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("bridge.json");
    std::fs::write(
        &path,
        r#"{"v":2,"pid":1,"port":1234,"token":"12345678901234567890123456789012"}"#,
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    assert!(read_discovery(&path).is_err());
    let d = expert_tui::launcher::Discovery {
        v: 1,
        pid: 1,
        port: 1234,
        token: "SECRET".into(),
    };
    assert!(!format!("{d:?}").contains("SECRET"));
}

fn private_discovery(port: u16) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    #[cfg(windows)]
    {
        let status=std::process::Command::new("powershell.exe").args(["-NoProfile","-NonInteractive","-Command","$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; $a=New-Object Security.AccessControl.DirectorySecurity; $a.SetOwner($sid); $a.SetAccessRuleProtection($true,$false); foreach($s in @($sid,[Security.Principal.SecurityIdentifier]'S-1-5-18')){$a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($s,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}; Set-Acl -LiteralPath $env:EXPERT_TEST_DIR -AclObject $a"]).env_remove("PSModulePath").env("EXPERT_TEST_DIR",dir.path()).status().unwrap();
        assert!(status.success());
    }
    let path = dir.path().join("bridge.json");
    std::fs::write(&path,json!({"v":1,"pid":std::process::id(),"port":port,"token":"test-private-token-0123456789-abcdef"}).to_string()).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
    (dir, path)
}
fn read_wire(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> serde_json::Value {
    serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap()
}
fn reply(
    ws: &mut tungstenite::WebSocket<std::net::TcpStream>,
    request: &serde_json::Value,
    result: serde_json::Value,
) {
    ws.send(tungstenite::Message::Text(
        json!({"v":1,"id":request["id"],"ok":true,"result":result})
            .to_string()
            .into(),
    ))
    .unwrap();
}
#[test]
fn live_worker_authenticates_reconnects_without_replaying_and_disconnect_does_not_stop() {
    use expert_tui::source::BridgeSource;
    use std::{
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (_dir, path) = private_discovery(listener.local_addr().unwrap().port());
    assert!(read_discovery(&path).is_ok());
    let server = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let hello = read_wire(&mut ws);
        assert_eq!(hello["method"], "hello");
        assert_eq!(
            hello["params"]["token"],
            "test-private-token-0123456789-abcdef"
        );
        reply(&mut ws, &hello, json!({"protocol":1,"server_id":"first"}));
        let snapshot = read_wire(&mut ws);
        assert_eq!(snapshot["method"], "snapshot.get");
        reply(
            &mut ws,
            &snapshot,
            json!({"session":{"id":"s","status":"idle"}}),
        );
        let message = read_wire(&mut ws);
        assert_eq!(message["method"], "message.send");
        drop(ws);
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let hello = read_wire(&mut ws);
        reply(&mut ws, &hello, json!({"protocol":1,"server_id":"second"}));
        let open = read_wire(&mut ws);
        assert_eq!(open["method"], "session.open");
        reply(
            &mut ws,
            &open,
            json!({"session":{"id":"s","status":"running"}}),
        );
        for text in ["A", "DUPLICATE"] {
            ws.send(tungstenite::Message::Text(json!({"v":1,"type":"event","seq":1,"session_id":"s","event":"assistant.delta","data":{"message_id":"m","text":text}}).to_string().into())).unwrap();
        }
        match ws.read() {
            Ok(tungstenite::Message::Close(_)) | Err(_) => {}
            Ok(other) => panic!("Unexpected replay or stop on disconnect: {other:?}"),
        }
    });
    let mut source = BridgeSource::new(path);
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut sent = false;
    let mut refreshed = false;
    let mut unknown = false;
    let mut deltas = 0;
    while Instant::now() < deadline {
        for event in source.poll() {
            match event {
                SourceEvent::Snapshot(v) if v["session"]["status"] == "idle" && !sent => {
                    source
                        .send(Command {
                            method: "message.send".into(),
                            params: json!({"session_id":"s","text":"hi"}),
                        })
                        .unwrap();
                    sent = true;
                }
                SourceEvent::Snapshot(v) if v["session"]["status"] == "running" => refreshed = true,
                SourceEvent::Error(e) => unknown |= e.contains("unknown"),
                SourceEvent::Event(v) if v["event"] == "assistant.delta" => deltas += 1,
                _ => {}
            }
        }
        if refreshed && unknown && deltas == 1 {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(sent && refreshed && unknown);
    thread::sleep(Duration::from_millis(150));
    deltas += source
        .poll()
        .into_iter()
        .filter(|e| matches!(e,SourceEvent::Event(v) if v["event"]=="assistant.delta"))
        .count();
    assert_eq!(deltas, 1);
    drop(source);
    server.join().unwrap();
}

#[test]
fn authentication_failure_never_exposes_snapshot_or_token() {
    use expert_tui::source::BridgeSource;
    use std::{
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (_dir, path) = private_discovery(listener.local_addr().unwrap().port());
    let server = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let hello = read_wire(&mut ws);
        ws.send(tungstenite::Message::Text(json!({"v":1,"id":hello["id"],"ok":false,"error":{"code":"unauthorized","message":"bad token"}}).to_string().into())).unwrap();
    });
    let mut source = BridgeSource::new(path);
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut rejected = false;
    while Instant::now() < deadline {
        for event in source.poll() {
            assert!(!format!("{event:?}").contains("test-private-token"));
            assert!(!matches!(event, SourceEvent::Snapshot(_)));
            if matches!(
                event,
                SourceEvent::Connection {
                    connected: false,
                    ..
                }
            ) {
                rejected = true;
            }
        }
        if rejected {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(rejected);
    drop(source);
    server.join().unwrap();
}

#[test]
fn failed_open_preserves_the_acknowledged_session_on_reconnect() {
    use expert_tui::source::BridgeSource;
    use std::{
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (_dir, path) = private_discovery(listener.local_addr().unwrap().port());
    let server = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(8))).unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let hello = read_wire(&mut ws);
        reply(&mut ws, &hello, json!({"protocol":1}));
        let initial = read_wire(&mut ws);
        reply(
            &mut ws,
            &initial,
            json!({"session":{"id":"acknowledged","status":"idle"}}),
        );
        let open = read_wire(&mut ws);
        assert_eq!(open["params"]["session_id"], "missing");
        ws.send(tungstenite::Message::Text(json!({"v":1,"id":open["id"],"ok":false,"error":{"code":"not_found","message":"会话不存在"}}).to_string().into())).unwrap();
        drop(ws);
        let (tcp, _) = listener.accept().unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let hello = read_wire(&mut ws);
        reply(&mut ws, &hello, json!({"protocol":1}));
        let restored = read_wire(&mut ws);
        assert_eq!(restored["method"], "session.open");
        assert_eq!(restored["params"]["session_id"], "acknowledged");
        reply(
            &mut ws,
            &restored,
            json!({"session":{"id":"acknowledged","status":"restored"}}),
        );
    });
    let mut source = BridgeSource::new(path);
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut sent = false;
    let mut restored = false;
    let mut actual_error = false;
    while Instant::now() < deadline {
        for event in source.poll() {
            match event {
                SourceEvent::Snapshot(v) if v["session"]["status"] == "idle" && !sent => {
                    source
                        .send(Command {
                            method: "session.open".into(),
                            params: json!({"session_id":"missing"}),
                        })
                        .unwrap();
                    sent = true;
                }
                SourceEvent::Snapshot(v) if v["session"]["status"] == "restored" => restored = true,
                SourceEvent::Error(message) => actual_error |= message.contains("会话不存在"),
                _ => {}
            }
        }
        if restored {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(sent && restored && actual_error);
    drop(source);
    server.join().unwrap();
}

#[test]
fn unauthenticated_event_flood_is_bounded_and_never_reaches_the_reducer() {
    use expert_tui::source::BridgeSource;
    use std::{
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let (_dir, path) = private_discovery(listener.local_addr().unwrap().port());
    let server = thread::spawn(move || {
        let (tcp, _) = listener.accept().unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut ws = tungstenite::accept(tcp).unwrap();
        let _hello = read_wire(&mut ws);
        let end = Instant::now() + Duration::from_secs(7);
        while Instant::now() < end {
            if ws.send(tungstenite::Message::Text(json!({"v":1,"type":"event","seq":1,"event":"snapshot","data":{"session":{"id":"unauthenticated"}}}).to_string().into())).is_err(){break;}
            thread::sleep(Duration::from_millis(10));
        }
    });
    let mut source = BridgeSource::new(path);
    let deadline = Instant::now() + Duration::from_secs(7);
    let mut expired = false;
    while Instant::now() < deadline {
        for event in source.poll() {
            assert!(!matches!(
                event,
                SourceEvent::Snapshot(_) | SourceEvent::Event(_)
            ));
            if matches!(
                event,
                SourceEvent::Connection {
                    connected: false,
                    ..
                }
            ) {
                expired = true;
            }
        }
        if expired {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        expired,
        "Hello deadline must apply despite continual unauthenticated frames"
    );
    drop(source);
    server.join().unwrap();
}
