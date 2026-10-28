use crate::app::{App, Command};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::json;

/// Choices on the first-visit folder trust screen, in display order.
pub const TRUST_CHOICES: &[&str] = &[
    "信任此文件夹（读写）",
    "信任此文件夹（只读）",
    "不信任，退出",
];

impl App {
    /// An unregistered folder must be trusted before any workspace UI appears.
    pub fn ask_trust(&mut self, path: &str) {
        self.trust_prompt = Some(path.to_owned());
        self.trust_choice = 0;
        self.workspace_pending = false;
    }
    pub fn trust_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let Some(path) = self.trust_prompt.clone() else {
            return vec![];
        };
        let n = TRUST_CHOICES.len();
        let choice = match key.code {
            KeyCode::Up | KeyCode::BackTab => {
                self.trust_choice = (self.trust_choice + n - 1) % n;
                return vec![];
            }
            KeyCode::Down | KeyCode::Tab => {
                self.trust_choice = (self.trust_choice + 1) % n;
                return vec![];
            }
            KeyCode::Char(c @ '1'..='3') => c as usize - '1' as usize,
            KeyCode::Enter => self.trust_choice,
            KeyCode::Esc => n - 1,
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => n - 1,
            _ => return vec![],
        };
        if choice == n - 1 {
            self.exit = true;
            return vec![];
        }
        self.trust_prompt = None;
        self.workspace_pending = true;
        self.notice.clear();
        vec![Command {
            method: "workspace.register".into(),
            params: json!({
                "path": path,
                "access": if choice == 0 { "read-write" } else { "read-only" },
                "confirmed": true,
            }),
        }]
    }
}
