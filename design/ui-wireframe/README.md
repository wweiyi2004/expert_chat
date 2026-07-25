# Expert Chat · UI 产品级可点原型

阶段 0：验证**手机优先**信息架构；视觉按上线标准打样。

## 打开

```powershell
start design/ui-wireframe/index.html
```

需联网加载：

- Google Fonts：`DM Sans` + `Noto Sans SC`
- Material Symbols Outlined
- DiceBear 角色头像（固定 seed，可换成本地/用户上传）

## 设计系统（阶段 1 应对齐）

| 项 | 约定 |
|----|------|
| 图标 | Material Symbols Outlined，选中 Tab `FILL=1` |
| 角色头像 | 统一圆形/圆角矩形；故事会话旁路角色头像，助手可用品牌标 |
| 模式色 | 对话青 `#1F5C6B` / 故事琥珀 `#C45C26` / 乱斗紫 `#5B4B8A` |
| 字体 | 西文 DM Sans 或系统；中文 Noto Sans SC / 系统 CJK |
| 底栏 | 会话 · 创作 · 我的 |

## 可点路径

底栏三 Tab、会话列表筛选、情节 Sheet、新建菜单、角色详情「开始故事」、我的 → Provider/联网、平板双栏示意。

确认后进入 **阶段 1 Flutter 实现**。
