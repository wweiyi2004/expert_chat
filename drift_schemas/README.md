**数据库结构快照**

- `drift_schema_v15.json` 从发布提交 `072dc8c` 的 `app_database.dart` 和配套生成文件导出，不是从当前结构手动删列拼成。
- `drift_schema_v16.json` 保留加入项目与生图记录时的历史结构。
- `drift_schema_v17.json` 从当前应用定义导出，生图记录增加可空的接口格式；旧记录保持未知。
- `test/generated_migrations/` 由 `dart run drift_dev schema generate drift_schemas test/generated_migrations` 生成。
- `test/schema_migration_test.dart` 校验 v15→v17 的结构、历史消息和分支，以及 v16→v17 生图记录参数保留；现有 v8 回归和原生磁盘恢复测试继续保留。

版本演进时保留旧快照，新增新版本并验证明确支持的升级起点。当前快照矩阵不等于所有更旧版本/所有设备都已经过完整迁移验收。
