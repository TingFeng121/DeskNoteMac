# 第三方前端渲染库

`MarkdownRenderer/` 里的渲染能力全部来自下列开源项目。应用**不联网**：这些文件被原样打进
`.app`，读者拿到的字节和仓库里的一模一样，因此每个文件的 SHA-256 都记在 `VERSIONS.json`，
升级时要重新下载官方产物、重新核对 registry 的 `sha512`、重新记录，不接受手改。

| 包 | 版本 | 许可证 | 带的文件 | 用途 |
|---|---|---|---|---|
| markdown-it | 15.0.3 | MIT | `vendor/markdown-it.min.js` | CommonMark + GFM 表格/删除线解析 |
| markdown-it-footnote | 4.0.0 | MIT | `vendor/markdown-it-footnote.min.js` | `[^标注]` 脚注 |
| DOMPurify | 3.4.17 | MPL-2.0 OR Apache-2.0（取其一即可用） | `vendor/purify.min.js` | 正文里手写的 HTML 在插入页面前清洗 |
| highlight.js | 11.12.0 | BSD-3-Clause | `vendor/highlight.min.js` | 代码块高亮，官方 "common languages" 构建，内含 36 种语言 |
| KaTeX | 0.19.1 | MIT | `vendor/katex/katex.min.js`、`katex.min.css`、`contrib/auto-render.min.js`、`fonts/*.woff2` | `$…$` / `$$…$$` 公式排版 |
| mermaid | 12.2.0 | MIT | `vendor/mermaid/mermaid.min.js` | ` ```mermaid ` 围栏出流程图/时序图 |

完整许可证文本在 `licenses/`。

## 打包上的三个取舍

- **highlight.js 只带常用 36 种语言**（bash、c、cpp、csharp、css、diff、go、graphql、ini、java、
  javascript、json、kotlin、less、lua、makefile、markdown、objectivec、perl、php、plaintext、
  python、python-repl、r、ruby、rust、scss、shell、sql、swift、typescript、vbnet、wasm、xml、yaml）。
  其余 157 种语言按需另取，不在本轮范围内。
- **没有带 highlight.js 的主题 CSS**。配色由 `renderer.css` 自己写在 `.hljs-*` token 类上，
  浅色/深色跟着 App 的调色走，而不是把某个第三方主题的颜色塞进便签里。
- **KaTeX 只带 woff2 字体**。`katex.min.css` 的 `@font-face` 把 woff2 排在 `src` 首位，支持的引擎
  不会再请求 woff/ttf，于是省下 0.8 MB。字体文件本身一个字节没改。
- **mermaid 的产物是官方单文件 UMD 包**，里面还嵌着它自己依赖（d3、dagre、cytoscape 等）的版权声明，
  都留在文件头部的注释里，未做删减。

## 不属于这里的东西

mermaid ≠ Obsidian 插件系统。这套渲染只做「开箱就能画出来的东西」：代码高亮、公式、Mermaid 图、
GFM callout、脚注、`[[双向链接]]`。用户脚本、Dataview、社区插件一律不支持，`renderer.js` 里
也没有留给它们注入的口子。
