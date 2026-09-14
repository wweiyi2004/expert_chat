# HTML / SVG 本地预览

HTML、HTM、XHTML、SVG 代码块右上角提供“预览”。无语言标记的 HTML/SVG、XML 标记的 SVG，以及直接粘贴的完整 HTML/SVG 文档也可识别；消息操作栏提供“本地预览 HTML / SVG”，自己的消息和模型回复都能使用。

只有闭合的代码块显示入口，未输出完整的流式代码不会提前执行。普通 Dart、Python、JavaScript 源码块不会被当作页面执行。HTML 内的 CSS 和 JavaScript 可以正常参与页面渲染和交互。

## 预览页

- Windows 使用 WebView2 内嵌渲染；Android、iOS、macOS 沿用 WebView；网页版使用隔离的 iframe 在当前页面内预览。
- 切换“源码”可编辑当前片段，“运行预览”将修改应用到预览。
- 桌面可切换 360 / 390 / 430 像素手机宽度；手机直接使用可用屏幕宽度，工具栏采用紧凑按钮，并避开底部安全区。支持刷新和多个片段前后切换，各片段的编辑草稿相互独立。
- “复制源码”保留原始 HTML 片段或 SVG 内容，不混入预览包装层。
- 修改只保留在当前预览页，不覆盖聊天记录，也不发起模型调用。
- 内嵌组件不可用时可以主动使用“在浏览器打开”。不同内容的临时 HTML 使用内容哈希命名，避免后开的预览覆盖先前页面。

SVG 会包装进 HTML 文档以适配窗口，保留原始 SVG 作为编辑和复制内容。缺少 `viewBox` 但有明确像素宽高的 SVG 会在渲染副本中补充坐标范围，避免缩窄后裁切。HTML 片段会补充文档结构、字符集、视口以及图片缩放和代码滚动的默认样式；完整 HTML 缺少 viewport 时补充，已有 viewport 和原始源码保留。

宽度切换使用真实渲染视口，页面的 CSS 媒体查询可以参与布局，切换宽度不刷新页面。它不模拟手机系统、触摸硬件或 User-Agent；固定桌面宽度、多栏导航等仍需要网页自身提供响应式 CSS。预览器不会强制重写完整页面的样式。

## 本地执行边界

预览继续使用已有的 `buildSandboxedHtmlPreview`：生成代码位于隔离的 iframe 内，允许内联 CSS/JavaScript，阻止外部资源、网络请求、表单提交、弹窗和顶层导航。依赖 CDN、远程字体或远程接口的页面不会完整运行，需要改为自包含页面或内嵌资源。

Windows 浏览器数据存放在应用支持目录下的独立 `code-preview-webview` 子目录；不映射聊天数据或本机文件目录，不提供应用功能的 JavaScript 桥接。预览刷新、切换源码和离开页面时释放对应的 Windows WebView 控制器。

Windows 内嵌实现使用 [webview_windows 0.4.0](https://pub.dev/packages/webview_windows)，依赖 WebView2 Runtime。新增原生插件需要完整安装包更新，不能仅通过 Dart OTA 将本功能加入不含该插件的旧安装包。

## 验证入口

```powershell
flutter test --no-pub test/local_code_preview_test.dart test/html_snippet_test.dart
flutter test --no-pub --platform chrome test/local_html_surface_web_test.dart
flutter test --no-pub integration_test/local_code_preview_test.dart -d windows
```

组件测试检查识别、流式闭合、源码修改、复制、多片段草稿和窄屏布局。Windows 集成测试使用真实 WebView2，检查内联 JavaScript 点击交互、CSS 计算结果、SVG 几何渲染、隔离访问和 HTTP 请求拦截，以及重新创建和释放预览组件；测试不读取聊天记录或调用真实模型。

2026-09-14 验证结果：全量 Flutter 测试 1122 项通过、1 项原有跳过；静态检查无问题。Windows 原生集成测试 1 项通过，使用真实 WebView2 验证按钮交互、CSS 颜色、SVG 图形尺寸及网络隔离。

2026-09-15 手机适配验证：全量 Flutter 测试 1125 项通过、1 项原有跳过；静态检查与 Web 构建通过。Chrome 使用真实 iframe 验证桌面双栏与 360 / 390 / 430 像素单栏之间切换、页面状态保留及父页面访问隔离。浏览器组件测试使用 Live binding，并启用真实 platform messages，避免默认测试环境跳过 iframe 创建和挂载。

本机 Windows Flutter 测试服务器将 CanvasKit 路径转换为反斜杠，导致资源路由返回 404。验证时临时将当前 SDK 的 `canvaskit/chromium/canvaskit.js` 和 `canvaskit.wasm` 放到 `test/canvaskit/chromium/`，由测试静态资源路由提供，结束后删除；未修改 SDK，正常 Web 构建不受影响。
