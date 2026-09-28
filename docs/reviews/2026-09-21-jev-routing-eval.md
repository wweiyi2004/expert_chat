# Jev 技能路由真实接口测试

日期：2026-09-21。模型：`jev-latest`。使用 Expert Chat 已保存的 TypeSafe 凭证，通过项目 `JevClient` 调用官方原生 API；仅发送 `tool/jev_routing_eval.dart` 内的固定中文样例，不发送实际聊天记录。密钥未写入报告或日志。

| 样例 | 预期分类 | 实际分类 | 置信度 | 端到端耗时 |
|---|---|---|---|---|
| Dart 空指针排查 | code | code | 1.0 | 1145 ms |
| Python 二分查找 | code | code | 1.0 | 980 ms |
| 英译中 | translate | translate | 1.0 | 709 ms |
| 邮件中译英 | translate | translate | 1.0 | 665 ms |
| 通知润色 | writing | writing | 1.0 | 717 ms |
| 婚礼开场白 | writing | writing | 1.0 | 1180 ms |
| 会议记录提炼 | summarize | summarize | 1.0 | 992 ms |
| 文章观点总结 | summarize | summarize | 1.0 | 725 ms |
| 编写猫咪生图提示词 | image-prompt | image-prompt | 1.0 | 1831 ms |
| 通用问候 | general | general | 1.0 | 2655 ms |

结果：10/10 与预期一致，无请求失败或超时。平均耗时 1159.9 ms，范围 665–2655 ms，最近秩 P95 为 2655 ms；耗时包含本机网络往返。默认 0.6 阈值下，10 次结果均被接受。

这是一次顺序执行的简单样例测试，验证了真实 API 连通性及基础中文技能分类。未覆盖含糊意图、多轮指代、生产数据和持续并发，不能将本次 100% 结果视为生产准确率或置信度校准证据。最长请求接近当前 3 秒上限，网络波动时仍可能回退。本次未修改应用开关或阈值。
