# Expert TUI Bridge v1

JSON UTF-8 over `ws://127.0.0.1:<port>/tui`。Schema：`protocol.schema.json`。发现文件位置见 ARCHITECTURE。最多 1 MiB 请求、8 MiB 快照；超限明确失败，不静默省略验收证据。客户端禁止渲染输入中的 ANSI/OSC 控制序列。

## 信封与连接

请求：`{"v":1,"id":"client:uuid","method":"hello","params":{"protocol":1,"token":"...","client_id":"..."}}`

成功：`{"v":1,"id":"client:uuid","ok":true,"result":{...}}`

失败：`{"v":1,"id":"client:uuid","ok":false,"error":{"code":"busy","message":"任务运行中不能切换位置","retryable":false}}`

事件：`{"v":1,"type":"event","seq":1,"session_id":"...","event":"snapshot","data":{...}}`

hello 必须首个请求，5 秒内完成，返回 `{protocol:1,server_id,pid,capabilities:[方法名]}`。token 不入日志、不返回错误详情。每 15 秒 `ping` → `{time:ISO}`，超过 45 秒无响应重连。重连时重新 hello，然后 session.open / snapshot.get；不根据遗漏的增量猜状态。seq 在每个连接内严格增长。

请求串行修改同一会话，长时间模型生成先 ACK `{accepted:true}`，异步发布状态。服务至少保留当前进程最近 512 个请求 id 的结果；同 id 不重做操作。新连接不自动补发；读取快照确认。无/失效/他会话对象 id 拒绝。未知方法返回 unsupported，不静默成功。

## 请求列表

所有会话操作显式 `session_id`；没有时不得隐式作用于 GUI 当前会话。

| method | params | result |
|---|---|---|
| hello | protocol,token,client_id | protocol,server_id,pid,capabilities |
| ping | {} | time |
| snapshot.get | session_id? | 完整快照 |
| session.list | workspace_id? | sessions:Session[] |
| session.new | title?,workspace_id? | session_id；新工作会话，不覆盖现有会话 |
| session.open | session_id | 快照，绑定该连接的事件订阅，不取消其他会话 |
| message.send | session_id,text,attachments? | accepted；运行中返回 busy，客户端改用 queue.add |
| queue.add | session_id,text | id，持久化后确认 |
| queue.remove | session_id,id | text，仅 queued 可撤回 |
| task.stop | session_id | accepted |
| task.resume | session_id | accepted，明确继续而非自动重放操作 |
| approval.decide | session_id,id,decision:once/session/reject/reject_reason,reason? | accepted，session 精确匹配本次完整参数和目标 |
| question.answer | session_id,id,answers | accepted，走原有必答/选项校验 |
| models.list | {} | models:Model[] |
| model.set | session_id,choice,thinking,effort | accepted，choice 含来源 id |
| permission.set | session_id,permission:request/assisted/full,confirmed? | accepted；full 必须 confirmed:true（客户端第二次确认） |
| mode.set | session_id,mode:work/plan | accepted，不能变成普通 chat 会话 |
| workspace.list | {} | workspaces:Workspace[] |
| workspace.prepare | path | workspace 或 {confirmation_required:true,path}；只读查询，无隐式注册 |
| workspace.register | path,access:read-only/read-write,confirmed:true | workspace；独立批准且保留已有授权 |
| workspace.set | session_id,workspace_id | accepted；任务活动时拒绝 |
| changes.list | session_id | changes:Change[] |
| changes.diff | session_id,id | id,path,diff:String[]，二进制需明确说明 |
| task.accept | session_id | accepted，调用 verifyAndAcceptTask 复核真实证据 |
| task.revise | session_id,text | accepted，新补充/新明确用户轮，不删除验收历史 |
| agents.list | session_id | agents:Agent[] |
| agent.message | session_id,id,text | accepted |
| agent.stop | session_id,id | accepted |
| files.list | session_id,query? | files:[{path,kind}]；从授权工具会话列出，不能随意遍历本机 |
| gui.open | session_id?,page?:session/settings/library/media,change_id? | accepted，唤起同一 GUI |
| bridge.stop | {} | accepted，仅关闭桥接，不停止任务 |

图片剪贴板/附件不通过任意 path 让服务器读文件；允许有大小限制的显式附件内容对象 `{name,mime,data_base64}`，校验类型和体积。跨平台剪贴板不可用时说明并提供文件入口，不假装粘贴成功。

## 唯一状态快照

所有数组允许为空；缺失实际数据时用 null/空数组，不填示例数据。快照字段：

```
{
  session: {id,title,status,phase,round,round_limit,elapsed_ms,mode,permission,
    model,model_choice,thinking,effort,workspace_id,workspace_label,workspace_path,
    branch,context_percent,error}, // 没有会话时 null
  startup: {version,workspace,workspace_path,branch,dirty_count,contexts:[],issues:[]},
  messages:[{id,role,text,thinking,attachments:[{name,mime,size}]}],
  steps:[{id,message_id,round_id,verb,object,status,tail:[],elapsed_ms,exit_code,
    added,removed,detail}],
  approvals:[{id,tool,arguments,target,reason,diff:[]}],
  questions:[{id,questions:[{id,question,options:[],multiple,required}]}],
  changes:[{id,path,kind,added,removed,diff:[],summary,round_id,message_id}],
  agents:[{id,parent_id,name,model,status,activity,elapsed_ms,output,task?,depth?}],
  queued:[{id,text,status}],
  models:[{choice,id,source_id,source,efforts:[],thinking_supported}],
  workspaces:[{id,name,path,access,remote}],
  sessions:[{id,title,status,workspace_id,updated_at}]
}
```

Session.status：idle/running/approval/retrying/waiting_acceptance/accepted/stopped/failed。
Step.status：queued/running/approval/done/failed/stopped。Agent.status：queued/running/waiting/completed/failed/cancelled/interrupted。
mode work/plan；permission request/assisted/full；effort 使用后端实际 wire 值，不能统一给所有模型虚构五挡。

agents 按父节点先于子节点的深度优先顺序输出；有当前任务根身份时只返回该根的树。task/depth 是可选只读元信息；客户端以 parent_id 绘制层级，并在快照排序变化时保持选中的 agent id。

## 增量事件

snapshot 为权威状态；其余事件让客户端低延迟更新，后续 snapshot 进行校准。两端必须共享事件夹具。

| event | data |
|---|---|
| snapshot | 上述完整快照 |
| round.started / round.ended | round,round_limit,status |
| assistant.delta | message_id,text（新增后缀，修订已有内容用 snapshot 替换） |
| thinking.started / thinking.ended | message_id；仅展示服务实际返回的 reasoning，不生成/泄露隐藏内容 |
| step.started / step.updated / step.ended | 完整 Step |
| agent.updated | 完整 Agent |
| approval.requested | 完整 Approval |
| changes.updated | changes:Change[] |
| request.retry | code,message,attempt,max_attempts,retry_after_ms（后端真实信息） |
| request.error | code,message,retryable |
| context.updated | context_percent:number|null |

fixture 可以以 snapshot 开始，再跟增量，最终 snapshot。DemoSource 和 BridgeSource 应用同一 reducer，不能各自维护互不相干的演示 UI。演示动作只更新本地演示状态，不联系真实 bridge。

## 最低安全/兼容测试

拒绝错误 token/版本/Origin/远程地址/超大消息；未认证不可查询会话；多连接显式会话隔离；重复请求不重复发送；断连不中断任务；reconnect 快照恢复；待批准不能显示正在运行；计划模式执行层阻止写/shell/未知工具；批准 id 防串会话；完整访问二次确认；workspace 运行锁；秘密字段不进入 snapshot；撤回消费竞态；acceptance 实际哈希复核失败不能显示成功。
