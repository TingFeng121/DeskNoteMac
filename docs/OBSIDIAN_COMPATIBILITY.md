# Obsidian Markdown 兼容性评估

## 建议

保留 DeskNote 的 SwiftUI / AppKit 外壳，先把阅读页的 Markdown 解析器换成成熟的 `markdown-it`，再用**按需创建、跨文档复用的单个 `WKWebView`**承载高级预览。KaTeX 和 Mermaid 只在正文包含对应内容时加载本地资源。文件树、编辑器、文件访问、同步和窗口仍由原生代码管理。

这比迁移到 Electron 更符合“低消耗、逐步接近 Obsidian”的目标：不必重写应用外壳，也不需要常驻 Node.js 与 Chromium。`WKWebView` 首次打开时仍有内存和启动成本，应只在库的阅读/分屏视图实际需要时创建，并在文档切换时复用。该建议是架构判断；尚未做运行时内存基准。

REA 适合作为**开发期观察和整理兼容案例的辅助流程**，不是应用运行时解析器。不要把 REA、Obsidian 私有 bundle 或用户库里的脚本作为 DeskNote 的运行依赖。

## 本地现状

- [Package.swift](../Package.swift) 是单一 Swift 可执行目标，没有 SwiftPM 外部依赖；应用以 SwiftUI / AppKit 为主。
- [MarkdownText.swift](../Sources/DeskNote/MarkdownText.swift) 用简单行规则识别标题、引用、列表、任务、分隔线和代码围栏；行内格式交给 Apple 的 `AttributedString(markdown:)`。
- [LibraryReader.swift](../Sources/DeskNote/LibraryReader.swift) 额外处理 Markdown 表格、`[[页面]]` 链接、`![[图片]]` / `![](图片)`、图片尺寸和本地图片安全解析。正文快照在后台解析并缓存。代码围栏保留为代码文本，没有语言级高亮；当前实现没有 KaTeX、MathJax 或 Mermaid 渲染。
- `Sources` 和 `Package.swift` 中没有 `WKWebView`、JavaScriptCore 或第三方 Markdown / 数学 / 图表解析依赖。演示材料里出现 Mermaid 围栏，只能证明有示例文本，不代表已有渲染器。

因此，当前缺口主要是完整的 Markdown tokenization、语言高亮、更多 Obsidian 语法和数学/图表渲染；编辑体验与库操作不需要迁到 Web 技术栈。

## 已安装 Obsidian 的静态证据

本机 `/Applications/Obsidian.app` 的 `Info.plist` 与两个 ASAR 内的 `package.json` 均标为 **1.13.7**。以下文件路径、字节数和 SHA-256 来自 `obsidian.asar` 索引；对列出的资源在内存中计算的 SHA-256 与索引值一致。只读取了归档头、元数据和指定资源字节，没有运行 Obsidian、执行 JavaScript 或把私有 bundle 复制进仓库。

| 资源路径 | 大小 | SHA-256 |
|---|---:|---|
| `obsidian.asar`（归档） | 25,787,463 B | `a52a7daf1e2460bae03de80f2816604bd16a56cd374fbe5ce8d1a9ef5604059d` |
| `/app.js` | 3,876,459 B | `8efbf581e259cabef4f9c9a34814cfe3c02863757377e56b3603933c50e89898` |
| `/lib/codemirror/markdown.js` | 44,078 B | `9c6321617db736c03d7d30eba30ad94d756652960370a709bf7556ff5c35d74f` |
| `/lib/prism.min.js` | 576,531 B | `9389ca2110991b037228c190018c94abcf25d1af0ad32fc51b78263660acbddb` |
| `/lib/mermaid.min.js` | 2,964,042 B | `6ef73c979e4636b0724eb3b4ee505e53e3a117e4cae31914ec5b2d64f27ff603` |
| `/lib/mathjax/tex-chtml-full.js` | 1,338,727 B | `440dde1db4eb1fd2c0be99fb5f8bf946f339a9e5dade55bcb069a1937a7fb803` |

`app.js` 的静态文本包含 Mermaid、MathJax、Prism、CodeMirror 和 `MarkdownRenderer` 等标识；ASAR 内没有独立的 KaTeX 文件。**这只能证明这些名称/资源存在于此安装包，不能证明具体运行路径、版本、配置、授权来源或核心功能如何调用。**文件名和体积也不能直接当作兼容承诺。安装包的 `package.json` 版本是可靠的版本来源；上述第三方库没有从此索引单独确认上游版本号。

## REA 的适用范围与未知项

REA（[morluto/rea](https://github.com/morluto/rea)）可作为开发期的黑盒观察工具，帮助把 Obsidian 可见行为转成兼容样例，例如：同一 Markdown 在阅读视图中的链接、嵌入、代码围栏、数学和图表显示。建议产物是可复核的输入/预期结果 fixture，而不是从 Obsidian bundle 拷贝实现。

这次没有运行 REA：当前工具没有 REA MCP，系统 `PATH` 中也没有 `node` / `npm`。因此下文的安装包结论来自 ASAR 元数据与有限静态字符串检查，不是 REA 执行结果。社区插件的语法、插件 API、设置差异、主题样式以及各 Obsidian 版本的变化都尚未验证；不得把这份清单描述成“完整 Obsidian 兼容”。

## 轻量实现边界

1. **解析与展示分开。** 用 `markdown-it` 建立 CommonMark/GFM 基线，在 token 层增加 DeskNote 明确承诺的 Obsidian 扩展；不要靠不断叠加正则同时承担整篇文档语法。
2. **只保留一个高级预览 WebView。** 阅读页或分屏首次需要 HTML 预览时再创建；切换文档只更新内容。普通便签卡片、源码编辑和文件树继续使用原生视图，不为每张卡片创建 WebView。
3. **本地资源按需启用。** KaTeX 只在出现 `$...$` / `$$...$$` 时加载；Mermaid 只在有相应 fenced block 时加载。KaTeX 可作为轻量首选，但其 TeX 宏覆盖与 Obsidian 当前版本是否一致未知；如兼容样例差异明显，再评估 MathJax。只选一个公式引擎，不同时常驻两套。
4. **代码围栏只解析和高亮，不执行。** 语言标签交给受控的语法高亮库；不运行代码块，也不加载 vault 中 `.obsidian/plugins` 下的 JavaScript。
5. **Web 安全按默认拒绝设计。** Markdown 原始 HTML 默认关闭；URL scheme 使用白名单；本地图片/附件限制在当前 vault；外链资源默认不自动请求；WKWebView 只接收必要的内部链接回调，不向 Markdown 暴露任意原生调用接口。图表输入只交给固定版本的本地 Mermaid 渲染器。
6. **依赖固定并可追溯。** 实现时记录各 JS/CSS/字体资源的上游版本、许可证和 SHA-256；不把 Obsidian ASAR 资源复制为 DeskNote 依赖。运行时不要求 Node；若构建步骤需要 Node，应明确作为开发依赖，而不是用户机器上的系统依赖。

## 兼容优先级

| 优先级 | 用户可见语法 | 说明 |
|---|---|---|
| P0 | CommonMark 常用块/行内语法、GFM 表格与任务、代码围栏和语言高亮 | 作为跨应用 Markdown 基线；测试含中文、长代码块和不完整围栏。 |
| P0 | `[[页面]]`、别名/标题链接、相对路径和本地图片 | 保留 DeskNote 现有内部链接解析；模糊匹配、大小写和 URL 编码要有明确规则。 |
| P1 | Obsidian callout、`![[页面]]` / `![[图片]]` 嵌入、标签和 frontmatter 展示 | 只展示受支持字段；不把 YAML 当脚本或自动执行查询。 |
| P1 | 行内/块级数学、Mermaid fenced block | KaTeX 与 Mermaid 本地按需加载，建立官方示例和真实文档 fixture。 |
| P2 | 块引用、复杂转录/跨文档嵌入、插件自定义语法和插件脚本 | 先保留源码或给出不支持提示；每项按独立需求评估，不承诺可运行第三方插件。 |

### 插件与脚本界线

核心应用只实现有文档、有 fixture、有版本承诺的语法扩展。第三方 Obsidian 插件常通过任意 JavaScript 修改解析器、命令和界面；若要支持，必须成为单独的显式选择功能，定义权限和兼容 API，并限制在隔离环境中。默认不发现、不加载、不执行 vault 中的插件包、脚本标签或代码围栏。无法解析的扩展应保留原文，不静默改写源文件。

## 建议的验证方式

用小型固定样例覆盖 P0/P1：输入 Markdown、预期结构/截图、内部链接目标和附件路径；在 DeskNote 版本间回归这些 fixture。若以后启用 REA，只用它记录 Obsidian 的可见输出并补充样例，再由 DeskNote 自己的测试验证，不把 REA 自动化或 Obsidian 私有 bundle 放进产品构建。
