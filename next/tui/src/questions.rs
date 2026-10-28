use crate::app::{App, Command, Draft, View, items, text};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Map, Value, json};
use std::collections::HashMap;

type RequestKey = (String, String);

#[derive(Debug, Clone, Default)]
struct Progress {
    index: usize,
    drafts: HashMap<String, String>,
    answers: Map<String, Value>,
}

#[derive(Debug, Default)]
pub struct QuestionUi {
    identity: Option<RequestKey>,
    saved: HashMap<RequestKey, Progress>,
    pub drafts: HashMap<String, String>,
    background: Option<Draft>,
    pub option: usize,
    pub editing: bool,
    pub hidden: bool,
    pub scroll: usize,
}

fn identity(snapshot: &Value) -> Option<RequestKey> {
    let request = items(snapshot, "questions").first()?;
    Some((
        text(&snapshot["session"], "id").into(),
        text(request, "id").into(),
    ))
}

pub fn parse_answer(question: &Value, input: &str) -> Result<Value, &'static str> {
    let input = input.trim();
    let options = items(question, "options");
    let tokens: Vec<_> = input.split(',').map(str::trim).collect();
    let numeric = !options.is_empty() && tokens.iter().any(|s| s.parse::<usize>().is_ok());
    let mut selected = vec![];
    if numeric {
        for token in tokens {
            let option = token
                .parse::<usize>()
                .ok()
                .and_then(|n| n.checked_sub(1))
                .and_then(|i| options.get(i))
                .ok_or("选项编号无效；请只输入有效编号，或直接填写文字说明")?;
            if !selected.contains(option) {
                selected.push(option.clone());
            }
        }
    }
    if question["multiple"] != true && selected.len() > 1 {
        return Err("请选择一个选项");
    }
    let answer = if selected.is_empty() { input } else { "" };
    if question["required"] == true && selected.is_empty() && answer.is_empty() {
        return Err("请回答此必答问题");
    }
    Ok(json!({"selected":selected,"text":answer}))
}

impl App {
    pub fn hide_questions(&mut self) {
        self.store_question_draft();
        self.question_ui.hidden = true;
        self.input.clear();
        self.cursor = 0;
        self.notice = "问题待回答；/questions 重新打开".into();
    }

    pub fn open_questions(&mut self) {
        self.question_ui.hidden = false;
        self.drawer = None;
        self.view = View::Chat;
        self.load_question_draft();
    }
    pub fn question_popup_visible(&self) -> bool {
        self.view == View::Chat
            && self.form.is_none()
            && self.drawer.is_none()
            && !self.question_ui.hidden
            && !items(&self.snapshot["questions"][0], "questions").is_empty()
    }

    pub fn current_question(&self) -> &Value {
        &self.snapshot["questions"][0]["questions"][self.question_index]
    }

    pub fn question_pending(&self) -> bool {
        let Some(key) = identity(&self.snapshot) else {
            return false;
        };
        self.answered_questions.contains(&key)
            || self.pending_inputs.iter().any(|p| {
                p.command.method == "question.answer"
                    && p.command.params["session_id"] == key.0
                    && p.command.params["id"] == key.1
            })
    }

    pub(crate) fn before_question_snapshot(&mut self, next: &Value) {
        if identity(&self.snapshot) == identity(next) {
            return;
        }
        if let Some(key) = identity(&self.snapshot) {
            self.store_question_draft();
            self.question_ui.saved.insert(
                key,
                Progress {
                    index: self.question_index,
                    drafts: self.question_ui.drafts.clone(),
                    answers: self.question_answers.clone(),
                },
            );
        }
        if let Some(mut draft) = self.question_ui.background.take() {
            if self.question_ui.hidden && !self.input.is_empty() {
                if !draft.text.is_empty() {
                    draft.text.push('\n');
                }
                draft.text.push_str(&self.input);
                draft.cursor = draft.text.len();
            }
            self.load_draft(draft);
        }
        self.question_ui.identity = None;
        self.question_ui.drafts.clear();
        self.question_ui.hidden = false;
        self.question_ui.editing = false;
        self.question_ui.scroll = 0;
    }

    pub(crate) fn after_question_snapshot(&mut self) {
        let Some(key) = identity(&self.snapshot) else {
            return;
        };
        if self.question_ui.identity.as_ref() == Some(&key) {
            return;
        }
        self.question_ui.background = Some(self.current_draft());
        self.load_draft(Draft::default());
        let progress = self.question_ui.saved.remove(&key).unwrap_or_default();
        self.question_index = progress.index.min(
            items(&self.snapshot["questions"][0], "questions")
                .len()
                .saturating_sub(1),
        );
        self.question_answers = progress.answers;
        self.question_ui.drafts = progress.drafts;
        self.question_ui.identity = Some(key);
        self.load_question_draft();
        self.send_after_binding = false;
    }

    fn store_question_draft(&mut self) {
        if self.question_ui.hidden || self.question_pending() {
            return;
        }
        let id = text(self.current_question(), "id").to_owned();
        if !id.is_empty() {
            self.question_ui.drafts.insert(id, self.input.clone());
        }
    }

    fn load_question_draft(&mut self) {
        let id = text(self.current_question(), "id");
        self.input = self.question_ui.drafts.get(id).cloned().unwrap_or_default();
        self.cursor = self.input.len();
        self.paste_collapsed = false;
        self.question_ui.option = self
            .input
            .split(',')
            .next()
            .and_then(|s| s.trim().parse::<usize>().ok())
            .and_then(|i| i.checked_sub(1))
            .unwrap_or(0);
        self.question_ui.editing = items(self.current_question(), "options").is_empty();
        self.question_ui.scroll = 0;
    }

    pub fn switch_question(&mut self, index: usize) {
        if self.question_pending() {
            return;
        }
        let count = items(&self.snapshot["questions"][0], "questions").len();
        if index >= count {
            return;
        }
        self.store_question_draft();
        self.question_index = index;
        self.load_question_draft();
        self.notice.clear();
    }

    pub fn choose_question_option(&mut self, index: usize) {
        if self.question_pending() || index >= items(self.current_question(), "options").len() {
            return;
        }
        let mut selected: Vec<usize> = self
            .input
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
        let value = index + 1;
        if self.current_question()["multiple"] != true {
            selected = vec![value];
        } else if selected.contains(&value) {
            selected.retain(|i| *i != value);
        } else {
            selected.push(value);
            selected.sort_unstable();
        }
        self.input = selected
            .iter()
            .map(usize::to_string)
            .collect::<Vec<_>>()
            .join(",");
        self.cursor = self.input.len();
        self.question_ui.option = index;
        self.question_ui.editing = false;
        self.store_question_draft();
    }

    pub fn submit_question_answers(&mut self) -> Vec<Command> {
        if self.question_pending() {
            self.notice = "答案已提交，等待服务器确认".into();
            return vec![];
        }
        self.store_question_draft();
        let questions = items(&self.snapshot["questions"][0], "questions").to_vec();
        if questions.is_empty() {
            return vec![];
        }
        let mut answers = Map::new();
        for (index, question) in questions.iter().enumerate() {
            let id = text(question, "id");
            match parse_answer(
                question,
                self.question_ui.drafts.get(id).map_or("", String::as_str),
            ) {
                Ok(value) => {
                    answers.insert(id.into(), value);
                }
                Err(error) => {
                    self.switch_question(index);
                    self.notice = format!("第 {} 题：{error}", index + 1);
                    return vec![];
                }
            }
        }
        self.question_answers = answers;
        let draft = self.current_draft();
        let command = self.command(
            "question.answer",
            json!({
                "id":self.snapshot["questions"][0]["id"],"answers":self.question_answers,
            }),
        );
        self.input.clear();
        self.cursor = 0;
        self.track_input(
            command,
            draft,
            Some((self.question_index, self.question_answers.clone())),
        )
    }

    pub(crate) fn answer_question(&mut self) -> Vec<Command> {
        if self.question_pending() {
            self.notice = "答案已提交，等待服务器确认".into();
            return vec![];
        }
        self.question_ui.hidden = false;
        match parse_answer(self.current_question(), &self.input) {
            Ok(value) => {
                self.question_answers
                    .insert(text(self.current_question(), "id").into(), value);
            }
            Err(error) => {
                self.notice = error.into();
                return vec![];
            }
        }
        let count = items(&self.snapshot["questions"][0], "questions").len();
        if self.question_index + 1 < count {
            self.switch_question(self.question_index + 1);
            vec![]
        } else {
            self.submit_question_answers()
        }
    }

    pub(crate) fn question_key(&mut self, key: KeyEvent) -> Option<Vec<Command>> {
        if !self.question_popup_visible() {
            return None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        // Commands remain available, including stop/quit while awaiting an answer.
        if key.code == KeyCode::Enter && Self::is_control_command(&self.input) {
            return None;
        }
        if key.code == KeyCode::Esc {
            self.hide_questions();
            return Some(vec![]);
        }
        if key.code == KeyCode::Enter && ctrl {
            return Some(self.submit_question_answers());
        }
        if ctrl || alt {
            return None;
        }
        if self.question_pending() {
            return match key.code {
                KeyCode::Enter => Some(self.answer_question()),
                _ if self.input.starts_with('/') || key.code == KeyCode::Char('/') => None,
                _ => Some(vec![]),
            };
        }
        let count = items(&self.snapshot["questions"][0], "questions").len();
        match key.code {
            KeyCode::Left | KeyCode::Right if !self.question_ui.editing => {
                let index = if key.code == KeyCode::Left {
                    (self.question_index + count - 1) % count
                } else {
                    (self.question_index + 1) % count
                };
                self.switch_question(index);
            }
            KeyCode::Tab | KeyCode::BackTab => {
                self.question_ui.editing = !self.question_ui.editing;
            }
            KeyCode::Up | KeyCode::Down if !self.question_ui.editing => {
                let n = items(self.current_question(), "options").len();
                if n > 0 {
                    self.question_ui.option = if key.code == KeyCode::Up {
                        (self.question_ui.option + n - 1) % n
                    } else {
                        (self.question_ui.option + 1) % n
                    };
                }
            }
            KeyCode::PageUp => self.question_ui.scroll = self.question_ui.scroll.saturating_sub(4),
            KeyCode::PageDown => {
                self.question_ui.scroll = self.question_ui.scroll.saturating_add(4)
            }
            KeyCode::Char(' ') if !self.question_ui.editing => {
                self.choose_question_option(self.question_ui.option)
            }
            KeyCode::Enter => {
                return Some(self.answer_question());
            }
            KeyCode::Char(c) => {
                self.question_ui.editing = true;
                self.insert(&c.to_string());
            }
            KeyCode::Backspace
            | KeyCode::Delete
            | KeyCode::Home
            | KeyCode::End
            | KeyCode::Left
            | KeyCode::Right => {
                self.question_ui.editing = true;
                self.edit_key(key);
            }
            _ => return None,
        }
        Some(vec![])
    }
}
