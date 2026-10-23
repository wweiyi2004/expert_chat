# GitHub 发版后自动同步 Gitee

工作流：`.github/workflows/sync-gitee-release.yaml`。

一次性配置完成后，在 GitHub 发布 Release 会同步版本标签、对应提交、标题、说明、预发布标记与全部上传附件。文件直接从 GitHub 下载，不重新编译；下载与上传后校验 SHA-256。相同附件重跑会跳过上传，冲突附件和冲突标签会报错，不强制覆盖。

## 一次性配置

1. 在 Gitee 创建自己的公开仓库，例如 `你的用户名/expert_chat`。
2. 在 [Gitee 私人令牌页面](https://gitee.com/profile/personal_access_tokens) 创建令牌，授予目标仓库所需的项目 API 和 Git 写入权限（通常为 `projects`）。使用令牌所属用户能写入的仓库。
3. 打开 GitHub 仓库 → Settings → Secrets and variables → Actions：
   - **Secrets** 新增 `GITEE_TOKEN`，值为 Gitee 私人令牌。
   - **Variables** 新增 `GITEE_REPO`，值为 `你的用户名/expert_chat`，不带域名和 `.git`。
4. 将工作流和 `scripts/sync_gitee_release.mjs` 推送到 GitHub 默认分支。当前本地修改不会自动出现在 GitHub。
5. 首次可在 Actions → **Sync release to Gitee** → **Run workflow** 输入现有 Release 标签进行验证，例如 `v3.7.0`。

令牌只配置在 GitHub Actions Secret 中，不放进仓库、软件设置或聊天消息。软件的公开下载源无需配置发布令牌。

## 日常发版

在 GitHub 创建草稿 Release，先上传正式安装包，再点击发布。同步任务完成后，Gitee 会出现同标签、同文件名、相同内容的附件。

如果发布后才补传附件，打开 Actions 手动指定该标签重跑。同步失败时同样可以重跑，已成功且校验一致的文件会保留。Gitee 的单附件大小、仓库配额或上传权限不满足时，任务会明确失败，不能绕过平台限制。

软件中填写：

```text
https://gitee.com/你的用户名/expert_chat/releases/download/{tag}/{file}
```

该工作流推送发布标签及其可达提交，不强制覆盖 Gitee 的分支或已有标签。

## 如果 GitHub Release 也是另一个 Action 创建的

使用仓库 `GITHUB_TOKEN` 创建 Release 通常不会再次触发 `release` 工作流。此时在发布任务之后调用本工作流：

```yaml
jobs:
  # 保留现有 publish 任务，并由它输出实际发布标签 outputs.tag。
  mirror-gitee:
    needs: publish
    uses: ./.github/workflows/sync-gitee-release.yaml
    with:
      tag: ${{ needs.publish.outputs.tag }}
    secrets:
      GITEE_TOKEN: ${{ secrets.GITEE_TOKEN }}
```

当前仓库只有校验与构建工作流，尚无自动发布 Release 的任务，因此先使用发布事件触发与手动补同步。新增发布任务后可以按上述方式串联。

## 本地验证

```powershell
node --check scripts/sync_gitee_release.mjs
node --test scripts/sync_gitee_release.test.mjs
```

测试覆盖首次同步、重复执行、部分成功后重试、同名冲突、哈希失败、缺少附件、分页、API 错误脱敏以及下载重定向不携带令牌。真实发布需要配置仓库和令牌后在 Actions 中验收。

接口参考：[Gitee Releases API](https://gitee.com/sdk/gitee5j/blob/main/docs/RepositoriesApi.md)、[Gitee 官方附件上传示例](https://gitee.com/oschina/mcp-gitee/blob/fc25f39cb63cc0c72765997a3bf288cebd9786fe/Makefile)、[GitHub 工作流触发规则](https://docs.github.com/en/actions/concepts/security/github_token)。
