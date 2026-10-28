use crate::app::{App, Command, FormKind, items, text};
use serde_json::{Value, json};

impl App {
    pub fn open_management(&mut self, area: &str) -> Vec<Command> {
        self.management_query(
            if area == "ssh" {
                "ssh.list"
            } else {
                "library.manage"
            },
            json!({}),
        )
    }
    fn management_query(&mut self, topic: &str, mut params: Value) -> Vec<Command> {
        self.extra_form(FormKind::Management, "正在读取…", vec![], json!({}));
        params["topic"] = json!(topic);
        params["_management"] = json!(true);
        params["ui_revision"] = json!(self.form_revision);
        vec![self.command("terminal.query", params)]
    }
    fn management_submit(&mut self, action: &str, mut params: Value) -> Vec<Command> {
        params["action"] = json!(action);
        params["_management"] = json!(true);
        params["ui_revision"] = json!(self.form_revision);
        let command = self.command("terminal.action", params);
        self.pending_form = Some((self.form_revision, command.clone()));
        if let Some(form) = self.form.as_mut() {
            self.pending_form_values = form.fields.clone();
            form.notice = "正在执行…".into();
        }
        vec![command]
    }
    pub fn management_cancel(&mut self) -> Vec<Command> {
        let Some(form) = self
            .form
            .as_ref()
            .filter(|f| f.kind == FormKind::Management)
        else {
            return vec![];
        };
        let Some(data) = form.items.first() else {
            return vec![];
        };
        if text(data, "management") != "ssh_progress"
            || data["done"] == true
            || text(data, "job_id").is_empty()
        {
            return vec![];
        }
        vec![self.command("terminal.action",json!({"action":"ssh.cancel","job_id":data["job_id"],"_management":true,"ui_revision":self.form_revision}))]
    }
    fn management_view(&mut self, data: Value) {
        let mut fields = vec![];
        let view = text(&data, "management");
        let title;
        match view {
            "ssh_list" => {
                title = "SSH 服务器".into();
                fields.push(Self::field("__new", "＋ 添加服务器", "", false, false));
                for (index, p) in items(&data, "profiles").iter().enumerate() {
                    fields.push(Self::field(
                        &format!("profile:{index}"),
                        &format!(
                            "{} · {}@{}:{}{}",
                            text(p, "name"),
                            text(p, "username"),
                            text(p, "host"),
                            p["port"],
                            if p["connected"] == true {
                                " · 已连接"
                            } else {
                                ""
                            }
                        ),
                        "",
                        false,
                        false,
                    ));
                }
                fields.push(Self::field("__refresh", "刷新状态", "", false, false));
            }
            "ssh_profile" => {
                title = if text(&data, "id").is_empty() {
                    "添加 SSH 服务器"
                } else {
                    "SSH 配置与连接"
                }
                .into();
                fields.extend([
                    Self::field("name", "服务器名称", text(&data, "name"), false, true),
                    Self::field("host", "主机地址", text(&data, "host"), false, true),
                    Self::field(
                        "port",
                        "端口",
                        &data["port"].as_i64().unwrap_or(22).to_string(),
                        false,
                        true,
                    ),
                    Self::field("username", "用户名", text(&data, "username"), false, true),
                    Self::field(
                        "remote_forward",
                        "RemoteForward（可选）",
                        text(&data, "remote_forward"),
                        false,
                        true,
                    ),
                    Self::field(
                        "forward_help",
                        "例：10808 127.0.0.1:7890",
                        "留空关闭；每行一条",
                        false,
                        false,
                    ),
                    Self::choice(
                        "authType",
                        "认证方式",
                        data["authType"].as_str().unwrap_or("password"),
                        &[("password", "密码"), ("privateKey", "私钥")],
                    ),
                    Self::field("password", "新密码（留空保留）", "", true, true),
                    Self::field(
                        "private_key_file",
                        "私钥文件路径（留空保留）",
                        "",
                        false,
                        true,
                    ),
                    Self::field("passphrase", "私钥口令（留空保留）", "", true, true),
                    Self::field("__save", "保存配置", "", false, false),
                ]);
                if !text(&data, "id").is_empty() {
                    fields.push(Self::field(
                        "__connect",
                        if data["connected"] == true {
                            "已连接 · 查看状态"
                        } else {
                            "连接服务器"
                        },
                        "",
                        false,
                        false,
                    ));
                    if data["connected"] == true {
                        fields.push(Self::field(
                            "__files",
                            "浏览远端文件 / 选择工作目录",
                            "",
                            false,
                            false,
                        ));
                        fields.push(Self::field("__disconnect", "断开 SSH", "", false, false));
                    }
                    fields.push(Self::field("__delete", "删除此配置", "", false, false));
                }
                fields.push(Self::field("__back", "返回服务器列表", "", false, false));
            }
            "ssh_progress" => {
                title = "SSH 连接".into();
                let challenge = &data["challenge"];
                if challenge.is_object() {
                    fields.push(Self::field(
                        "info",
                        "请核对服务器主机指纹",
                        "",
                        false,
                        false,
                    ));
                    fields.push(Self::field(
                        "fingerprint",
                        text(challenge, "fingerprint"),
                        "",
                        false,
                        false,
                    ));
                    fields.push(Self::field(
                        "key_type",
                        text(challenge, "key_type"),
                        "",
                        false,
                        false,
                    ));
                    if !text(challenge, "previous").is_empty() {
                        fields.push(Self::field(
                            "previous",
                            &format!("原指纹：{}", text(challenge, "previous")),
                            "",
                            false,
                            false,
                        ));
                    }
                    fields.push(Self::field("__reject", "取消连接", "", false, false));
                    fields.push(Self::field("__trust", "信任此指纹并继续", "", false, false));
                } else if data["done"] != true {
                    fields.push(Self::field("__reject", "取消连接", "", false, false));
                }
                fields.push(Self::field("__back", "返回服务器列表", "", false, false));
            }
            "ssh_files" => {
                title = format!("SSH 文件 · {}", text(&data, "path"));
                fields.push(Self::field(
                    "__use",
                    "将此目录作为当前会话工作区",
                    "",
                    false,
                    false,
                ));
                fields.push(Self::field("__parent", ".. 上一级", "", false, false));
                for (index, file) in items(&data, "files").iter().enumerate() {
                    fields.push(Self::field(
                        &format!("file:{index}"),
                        &format!(
                            "{}{}",
                            text(file, "name"),
                            if file["directory"] == true { "/" } else { "" }
                        ),
                        "",
                        false,
                        false,
                    ));
                }
                fields.push(Self::field("__back", "返回服务器列表", "", false, false));
            }
            "ssh_text" => {
                title = format!("SSH 文本 · {}", text(&data, "path"));
                fields.push(Self::field(
                    "text",
                    "文件正文（Alt+J 换行）",
                    text(&data, "text"),
                    false,
                    true,
                ));
                fields.push(Self::field("__write", "保存远端文件", "", false, false));
                fields.push(Self::field("__files", "返回文件目录", "", false, false));
            }
            "library_list" => {
                title = "资料库管理".into();
                fields.push(Self::field("__new", "＋ 新建资料集", "", false, false));
                fields.push(Self::field("path", "导入本机文件路径", "", false, true));
                fields.push(Self::field(
                    "__import",
                    "导入文件到资料库",
                    "",
                    false,
                    false,
                ));
                for (index, set) in items(&data, "sets").iter().enumerate() {
                    fields.push(Self::field(
                        &format!("set:{index}"),
                        &format!("资料集 · {} · {} 份", text(set, "name"), set["count"]),
                        "",
                        false,
                        false,
                    ));
                }
                for (index, file) in items(&data, "assets").iter().enumerate() {
                    fields.push(Self::field(
                        &format!("asset:{index}"),
                        &format!("管理文件 · {}", text(file, "name")),
                        "",
                        false,
                        false,
                    ));
                }
                fields.push(Self::field(
                    "__unbind",
                    "取消当前会话的资料集绑定",
                    "",
                    false,
                    false,
                ));
                fields.push(Self::field("__refresh", "刷新资料库", "", false, false));
            }
            "library_set" => {
                title = if text(&data, "id").is_empty() {
                    "新建资料集"
                } else {
                    "编辑资料集"
                }
                .into();
                fields.push(Self::field(
                    "name",
                    "资料集名称",
                    text(&data, "name"),
                    false,
                    true,
                ));
                fields.push(Self::field(
                    "instructions",
                    "资料集说明（Alt+J 换行）",
                    text(&data, "instructions"),
                    false,
                    true,
                ));
                for file in items(&data, "assets") {
                    fields.push(Self::choice(
                        &format!("include:{}", text(file, "id")),
                        text(file, "name"),
                        if file["selected"] == true {
                            "true"
                        } else {
                            "false"
                        },
                        &[("false", "不加入"), ("true", "加入")],
                    ));
                }
                fields.push(Self::field("__save", "保存资料集", "", false, false));
                if !text(&data, "id").is_empty() {
                    fields.push(Self::field(
                        "__use",
                        "当前会话使用此资料集",
                        "",
                        false,
                        false,
                    ));
                    fields.push(Self::field(
                        "__delete",
                        "删除资料集（保留文件）",
                        "",
                        false,
                        false,
                    ));
                }
                fields.push(Self::field("__back", "返回资料库", "", false, false));
            }
            "library_asset" => {
                title = format!("资料文件 · {}", text(&data, "name"));
                fields.push(Self::field(
                    "info",
                    &format!("{} · {} bytes", text(&data, "mime"), data["size"]),
                    "",
                    false,
                    false,
                ));
                fields.push(Self::field(
                    "__delete",
                    "从资料库删除此文件",
                    "",
                    false,
                    false,
                ));
                fields.push(Self::field("__back", "返回资料库", "", false, false));
            }
            _ => return,
        }
        self.extra_form(FormKind::Management, &title, fields, data.clone());
        let form = self.form.as_mut().unwrap();
        form.notice = if data["challenge"].is_object() {
            if text(&data["challenge"], "previous").is_empty() {
                "首次连接：核对指纹后选择信任；Esc 取消".into()
            } else {
                "服务器指纹发生变化，请核实后再信任；Esc 取消".into()
            }
        } else if !text(&data, "notice").is_empty() {
            text(&data, "notice").into()
        } else if !text(&data, "status").is_empty() {
            text(&data, "status").into()
        } else {
            "↑↓/Tab 选择 · Enter 执行 · Alt+J 换行 · Esc 关闭".into()
        };
        if data["challenge"].is_object() {
            form.selected = form
                .fields
                .iter()
                .position(|f| f.key == "__reject")
                .unwrap_or(0);
        }
    }
    pub fn management_form_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?.clone();
        if form.kind != FormKind::Management {
            return None;
        }
        let field = form.fields.get(form.selected)?;
        if field.editable {
            return None;
        }
        let data = form.items.first()?.clone();
        let view = text(&data, "management");
        let key = field.key.as_str();
        if self
            .pending_form
            .as_ref()
            .is_some_and(|(revision, _)| *revision == self.form_revision)
            && !(view == "ssh_progress" && (key == "__reject" || key == "__back"))
        {
            self.form.as_mut().unwrap().notice = "操作正在执行，请稍候；SSH 连接可取消".into();
            return Some(vec![]);
        }
        let get = |key: &str| {
            form.fields
                .iter()
                .find(|f| f.key == key)
                .map(|f| f.value.clone())
                .unwrap_or_default()
        };
        if ["__delete", "__disconnect", "__write"].contains(&key) {
            let identity = format!("management:{view}:{key}:{}", text(&data, "id"));
            if self.form_confirm.as_ref() != Some(&identity) {
                self.form_confirm = Some(identity);
                self.form.as_mut().unwrap().notice = "再次按 Enter 确认此操作；Esc 取消".into();
                return Some(vec![]);
            }
            self.form_confirm = None;
        }
        let connection = json!({"profile":data["profile"],"generation":data["generation"]});
        let commands=match (view,key) {
            ("ssh_list","__new")=>{self.management_view(json!({"management":"ssh_profile"}));vec![]}
            ("ssh_list",key) if key.starts_with("profile:")=>{
                let i=key[8..].parse::<usize>().ok()?;self.management_query("ssh.profile",json!({"id":data["profiles"][i]["id"]}))
            }
            ("ssh_list","__refresh")|("ssh_profile","__back")|("ssh_files","__back")=>self.open_management("ssh"),
            ("ssh_profile","__save")=>{
                let mut params=json!({"id":data["id"],"version":data["version"],"name":get("name"),"host":get("host"),"port":get("port"),"username":get("username"),"authType":get("authType"),"remote_forward":get("remote_forward")});
                for key in ["password","passphrase","private_key_file"]{if !get(key).is_empty(){params[key]=json!(get(key));}}
                self.management_submit("ssh.save",params)
            }
            ("ssh_profile","__connect")=>self.management_submit("ssh.connect",json!({"id":data["id"]})),
            ("ssh_profile","__files")=>self.management_query("ssh.files",connection),
            ("ssh_profile","__disconnect")=>{let mut p=connection;p["confirmed"]=json!(true);self.management_submit("ssh.disconnect",p)}
            ("ssh_profile","__delete")=>self.management_submit("ssh.delete",json!({"id":data["id"],"confirmed":true})),
            ("ssh_progress","__trust")=>self.management_submit("ssh.trust",json!({"job_id":data["job_id"],"challenge_id":data["challenge"]["id"],"accept":true})),
            ("ssh_progress","__reject")=>self.management_submit("ssh.cancel",json!({"job_id":data["job_id"]})),
            ("ssh_progress","__back")=>{let mut c=self.management_cancel();c.extend(self.open_management("ssh"));c}
            ("ssh_files","__parent")=>{let mut p=connection;p["path"]=data["parent"].clone();self.management_query("ssh.files",p)}
            ("ssh_files","__use")=>{let mut p=connection;p["path"]=data["path"].clone();self.management_submit("ssh.use",p)}
            ("ssh_files",key) if key.starts_with("file:")=>{
                let i=key[5..].parse::<usize>().ok()?;let file=&data["files"][i];let mut p=connection;p["path"]=file["path"].clone();
                self.management_query(if file["directory"]==true{"ssh.files"}else{"ssh.read"},p)
            }
            ("ssh_text","__write")=>{let mut p=connection;p["path"]=data["path"].clone();p["text"]=json!(get("text"));p["version"]=data["version"].clone();p["confirmed"]=json!(true);self.management_submit("ssh.write",p)}
            ("ssh_text","__files")=>{let mut p=connection;let path=text(&data,"path");p["path"]=json!(path.rsplit_once('/').map_or("/",|(d,_)|if d.is_empty(){"/"}else{d}));self.management_query("ssh.files",p)}
            ("library_list","__new")=>{
                let assets:Vec<_>=items(&data,"assets").iter().filter(|v|v["kind"]=="file").cloned().collect();
                self.management_view(json!({"management":"library_set","assets":assets}));vec![]
            }
            ("library_list","__import")=>self.management_submit("library.manage.import",json!({"path":get("path")})),
            ("library_list","__unbind")=>self.management_submit("library.manage.use",json!({"id":null})),
            ("library_list","__refresh")|("library_set","__back")|("library_asset","__back")=>self.open_management("library"),
            ("library_list",key) if key.starts_with("set:")=>{let i=key[4..].parse::<usize>().ok()?;self.management_query("library.manage.set",json!({"id":data["sets"][i]["id"]}))}
            ("library_list",key) if key.starts_with("asset:")=>{let i=key[6..].parse::<usize>().ok()?;let mut file=data["assets"][i].clone();file["management"]=json!("library_asset");self.management_view(file);vec![]}
            ("library_set","__save")=>{
                let ids:Vec<_>=form.fields.iter().filter(|f|f.key.starts_with("include:")&&f.value=="true").map(|f|f.key[8..].to_owned()).collect();
                self.management_submit("library.manage.save",json!({"id":data["id"],"version":data["version"],"name":get("name"),"instructions":get("instructions"),"file_ids":ids}))
            }
            ("library_set","__use")=>self.management_submit("library.manage.use",json!({"id":data["id"]})),
            ("library_set","__delete")=>self.management_submit("library.manage.delete",json!({"id":data["id"],"confirmed":true})),
            ("library_asset","__delete")=>self.management_submit("library.manage.remove",json!({"id":data["id"],"confirmed":true})),
            _=>vec![],
        };
        Some(commands)
    }
    pub fn management_response(&mut self, command: &Command, result: &Value) -> bool {
        if command.params["_management"] != true {
            return false;
        }
        if self
            .pending_form
            .as_ref()
            .is_some_and(|(_, c)| c == command)
        {
            self.pending_form = None;
        }
        if command.method == "terminal.action"
            && matches!(
                command.params["action"].as_str(),
                Some(
                    "ssh.use"
                        | "ssh.connect"
                        | "ssh.disconnect"
                        | "ssh.delete"
                        | "library.manage.use"
                        | "library.manage.delete"
                )
            )
        {
            self.outbox.push(self.command("snapshot.get", json!({})));
        }
        if !self
            .form
            .as_ref()
            .is_some_and(|f| f.kind == FormKind::Management)
            || command.params["ui_revision"].as_u64() != Some(self.form_revision)
        {
            return true;
        }
        if text(result, "management") == "ssh_progress"
            && result["done"] == true
            && result["connected"] == true
        {
            let c = self.management_query("ssh.profile", json!({"id":result["profile"]}));
            self.outbox.extend(c);
            return true;
        }
        self.management_view(result.clone());
        if text(result, "management") == "ssh_progress"
            && result["done"] != true
            && !result["challenge"].is_object()
        {
            self.outbox.push(self.command("terminal.query",json!({"topic":"ssh.status","job_id":result["job_id"],"_management":true,"ui_revision":self.form_revision})));
        }
        true
    }
}
