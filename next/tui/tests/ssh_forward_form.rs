use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::app::App;
use serde_json::json;
use std::time::Instant;

#[test]
fn ssh_forward_is_optional_loaded_saved_and_explicitly_clearable() {
    for value in ["", "10808 127.0.0.1:7890"] {
        let mut a = App::default();
        let command = a.open_management("ssh").remove(0);
        a.command_response(&command,&json!({"management":"ssh_profile","id":"ssh","version":"v1","name":"server","host":"example","port":5370,"username":"timer","remote_forward":value}));
        let form = a.form.as_ref().unwrap();
        let index = form
            .fields
            .iter()
            .position(|f| f.key == "remote_forward")
            .unwrap();
        assert_eq!(form.fields[index].value, value);
        assert!(form.fields[index].editable);
        a.form.as_mut().unwrap().fields[index].value = String::new();
        a.form.as_mut().unwrap().selected = a
            .form
            .as_ref()
            .unwrap()
            .fields
            .iter()
            .position(|f| f.key == "__save")
            .unwrap();
        let commands = a.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 120);
        assert_eq!(commands[0].params["action"], "ssh.save");
        assert_eq!(commands[0].params["remote_forward"], "");
        assert_eq!(commands[0].params["port"], "5370");
    }
}
