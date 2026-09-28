**Expert Chat 科研终端 UI 原型**

这是保留维护的实验 Web 参考界面；Flutter 客户端仍是主产品。原型使用 vinext、React 和 Cloudflare Worker，可选 D1/Drizzle，不承诺生产业务后端或持久化能力。

要求 Node.js 24。按锁安装并验证：

```sh
npm ci --registry=https://registry.npmjs.org
npm run typecheck
npm run lint
npm test
npm run audit
```

`npm test` 构建后在真实 workerd/Miniflare 环境中验证 Worker 的服务端渲染。Cloudflare 专有导入不能用 Node 默认 ESM loader 直接执行。`env.d.ts` 声明可选的 D1 `DB` 绑定；运行时未配置时仍会明确报错，不伪造数据库。

```sh
npm run dev
npm run build
npm run start
npm run db:generate
```

开发服务器仅用于受控本地环境，不作为长期公开服务。部署配置仍由 `.openai/hosting.json` 和 `vite.config.ts` 管理；本轮维护没有变更远端访问策略或发布站点。

依赖审计显式使用 npm 官方源，避免镜像不实现 audit API 导致误报安全。esbuild/fflate 的临时传递依赖覆盖及退出条件见 [依赖决策](../docs/DEPENDENCY-DECISIONS.md)。例行维护、贡献和发布证据要求与根项目一致。
