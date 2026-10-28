use crate::app::{App, Command, text};
use serde_json::{Value, json};
impl App {
    pub fn begin_attachment_import(&mut self, command: &mut Command, agent: Option<String>) {
        if command.params["session_id"].as_str() == self.session_id()
            && agent.as_deref() == self.agent_message_id.as_deref()
        {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
            let id = NEXT
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                .to_string();
            command.params["_client_attachment_id"] = json!(id);
            let path = std::path::Path::new(text(&command.params, "path"));
            let shown = text(&command.params, "display_name").to_owned();
            let mime = crate::attachment::mime(path);
            let kind = if mime.starts_with("image/") {
                "image"
            } else if mime.starts_with("audio/") {
                "audio"
            } else if mime.starts_with("video/") {
                "video"
            } else {
                "file"
            };
            self.insert_attachment_mark(json!({"_import_id":id,"_state":"loading","_path":path.to_string_lossy(),"kind":kind,"mime":mime,
                "name":if shown.is_empty(){path.file_name().unwrap_or_default().to_string_lossy().into_owned()}else{shown}}));
        }
        self.attachment_targets.push((command.clone(), agent));
    }
    pub fn finish_attachment_import(
        &mut self,
        command: &Command,
        value: Option<Value>,
        error: &str,
    ) -> bool {
        let Some(id) = command.params["_client_attachment_id"].as_str() else {
            return false;
        };
        let replace = |rows: &mut Vec<Value>| {
            if let Some(old) = rows.iter_mut().find(|a| text(a, "_import_id") == id) {
                if let Some(value) = &value {
                    let tag = old["_tag"].clone();
                    let path = old["_path"].clone();
                    *old = value.clone();
                    old["_tag"] = tag;
                    old["_path"] = path;
                    old["_state"] = json!("ready");
                } else {
                    old["_state"] = json!("error");
                    old["_error"] = json!(error);
                }
                true
            } else {
                false
            }
        };
        if replace(&mut self.attachments) {
            self.notice = if value.is_some() {
                "附件已就绪，可以发送".into()
            } else {
                format!("附件导入失败：{error} · /attachments 可查看或移除")
            };
            return true;
        }
        for draft in self.session_drafts.values_mut() {
            if replace(&mut draft.attachments) {
                return true;
            }
        }
        for pending in &mut self.recovered_inputs {
            if replace(&mut pending.draft.attachments) {
                return true;
            }
        }
        // A removed placeholder must not be resurrected by a late response.
        true
    }
    pub fn insert_attachment_mark(&mut self, mut value: Value) {
        let kind = match text(&value, "kind") {
            "image" => "Image",
            "audio" => "Audio",
            "video" => "Video",
            _ => "File",
        };
        let mut n = 1;
        while self
            .attachments
            .iter()
            .any(|a| text(a, "_tag") == format!("[{kind} {n}]"))
            || self.input.contains(&format!("[{kind} {n}]"))
        {
            n += 1;
        }
        let tag = format!("[{kind} {n}]");
        value["_tag"] = json!(tag);
        self.insert(&format!("{tag} "));
        self.paste_collapsed = false;
        self.long_input_expanded = true;
        self.attachments.push(value);
    }
    pub fn mark_at(&self, cursor: usize, left: bool) -> Option<(usize, usize)> {
        self.attachments
            .iter()
            .filter_map(|a| {
                let tag = text(a, "_tag");
                if tag.is_empty() {
                    return None;
                }
                self.input.match_indices(tag).find_map(|(start, _)| {
                    let end = start + tag.len();
                    if (left && cursor > start && cursor <= end)
                        || (!left && cursor >= start && cursor < end)
                    {
                        Some((start, end))
                    } else {
                        None
                    }
                })
            })
            .next()
    }
    pub fn remove_attachment(&mut self, index: usize) {
        if index >= self.attachments.len() {
            return;
        }
        let a = self.attachments.remove(index);
        let tag = text(&a, "_tag");
        if !tag.is_empty() {
            while let Some(start) = self.input.find(tag) {
                let end = start + tag.len();
                self.input.drain(start..end);
                self.cursor = if self.cursor >= end {
                    self.cursor - tag.len()
                } else if self.cursor > start {
                    start
                } else {
                    self.cursor
                };
            }
        }
    }
    pub fn sync_attachment_marks(&mut self) {
        // Search/form editors temporarily borrow the text input, but do not own its attachments.
        if self.drawer.is_none() && self.form.is_none() {
            self.attachments
                .retain(|a| text(a, "_tag").is_empty() || self.input.contains(text(a, "_tag")));
        }
    }
    pub fn restore_attachment_marks(&mut self) {
        let old = std::mem::take(&mut self.attachments);
        for a in old {
            let tag = text(&a, "_tag");
            if !tag.is_empty()
                && self.input.contains(tag)
                && !self.attachments.iter().any(|v| text(v, "_tag") == tag)
            {
                self.attachments.push(a);
            } else {
                self.cursor = self.input.len();
                self.insert_attachment_mark(a);
            }
        }
    }
}
