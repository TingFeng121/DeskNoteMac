# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

一个人：这台 Mac 的主人，同时是 DeskNote 的作者。笔记和待办是他每天每半小时都要碰的东西——开会记一行、路上想一件事、下午回头找上周写过什么。写作和整理长文发生在 Typora 或 Obsidian 里，DeskNote 负责的是速记、贴在桌面的那几张便签、以及待办板。他不愿意在两个地方各存一套笔记，也不愿意为了看一眼内容而切换 app。

## Product Purpose

把 DeskNote 从「数据锁在 data.json 里的便签 app」变成「文件优先的 Markdown 库客户端」：磁盘上一堆普通 .md 是唯一的真相，data.json 退成缓存。便签、待办、以及用户用外部编辑器写的长文，都在同一个库里；DeskNote 提供桌面层的速记与任务，加上这个库的浏览与检索。

成功＝他敢把真实的工作笔记放进这个库，在 Obsidian/Typora 里改完 DeskNote 能跟上，而且任何时候都不会有一份内容被静默覆盖或丢掉。

## Positioning

不是又一个 Markdown 编辑器，而是让「钉在桌面的便签 + 待办」这两件高频小事直接长在普通 .md 文件上。外部编辑器不需要插件就能打开同一个库；反过来，用户在别处写的文件，DeskNote 也能读、能搜、能顺着 `[[双链]]` 找回来。竞品要么把数据收进自己的仓库（Notion、备忘录），要么把桌面速记交给另一个 app（Obsidian + 另一个 to-do）。

## Operating Context

macOS 桌面常驻：主窗口默认 760×540、可拖边，左侧 72pt 色块边条 + 头部/搜索/内容三段；菜单栏面板、桌面钉住的便签浮窗、全局热键 ⌥⌘N、触发角新建便签。库目录随时可能被丢进 iCloud Drive（会同步到 Windows），也会被 git 仓库装着。WebDAV 备份已经存在，之后要改成同步整个库目录而不是整盘 JSON。

## Capabilities and Constraints

这一轮已确认的边界：

- DeskNote 负责**同步 + 便签与待办的读写 + 库的浏览与检索**（目录树、近文搜索与按需深搜、双链与反向链接）。现在也支持**任意 .md 的阅读、源码编辑与分屏预览**：文件树、新建 Markdown/文件夹、重命名、自动保存；保留原有 frontmatter，外部同时修改时另存编辑副本。
- 阅读模式的高级渲染**做**：代码语法高亮、Mermaid 图、KaTeX 公式、callout、脚注、内嵌 HTML 清洗后显示，全部走打进包里的本地资源，不联网、不装完整 Electron、不为每个块开一个 WebView；编辑与分屏仍是原生 `NSTextView`。**不做**用户脚本、Dataview、Obsidian 社区插件 API——能画 Mermaid 不等于能跑别人写的 JS，界面文案与 README 都不许这么写。
- 大库不靠运气：一轮同步只处理事件报上来的那几条路径，库的索引行只留正文前 32 KB，阅读解析按内容哈希缓存，超过 2 MB 的文档在后台装载且装载期间禁止写盘。任何一条「快」的说法都要有实测数字撑着，不接受「应该更快」。
- 库从 `data.json` 迁移出一个**新建的空库**，里面只有自己的便签和待办项目。**不做**「指向已有 Obsidian 库并批量导入」的流程。
- 入口是主窗口边条新增一个「库」分区（⌘4），与「全部／完成／便签」并列；不重做现有便签页。
- 文件身份只认 frontmatter 里的 `desknote.id`，不认文件名——用户在 Finder 或 Obsidian 里改名、挪目录之后要能认回来。
- 冲突与删除的底线：**绝不允许静默覆盖**。两边都改过就写一份 `…冲突 <时间>.md`，两份都留着；外部删掉的文件进 `.desknote/trash`，不进回收站也不硬删。
- 无损往返是硬要求：用户在 frontmatter 里自己写的 `tags`/`aliases`/嵌套块原样透传，正文首尾的空行一个不吃，CRLF 归一成 LF 但不吃内容。
- WebDAV 应用密码只存在钥匙串（service `local.desknote.app`，account `webdav`），不进 UserDefaults、不进日志。
- `~/Library/Application Support/DeskNote/data.json` 里是真实工作数据：迁移必须先落 `.bak`，且 data.json 继续留着当缓存，随时能退回文件层之前的版本。
- 构建方式固定：SwiftPM + `build-app.sh`，用本机自签证书 `DeskNote Local` 签名（designated requirement 钉成「同一张证书 + 同一个 bundle id」，为的是钥匙串不再反复问密码；`DESKNOTE_ALLOW_ADHOC=1` 才退回 ad-hoc），没有 Xcode 工程，离线也能构建——所以不轻易加第三方依赖。打进包里的渲染资源是**离线 vendor 的文件**（`MarkdownRenderer/`，逐文件 SHA-256 记账），不是运行时下载的依赖。
- 未决：图谱视图、标签面板、库是否将来替代便签页（当前决定：不替代）；WebDAV 切到目录同步的具体形态。

## Brand Commitments

中文界面文案：动词开头、短、不解释概念、不用 emoji、不加感叹号。既有视觉身份是既定事实，新功能只做扩展不做替换——低饱和色块边条、`panelLight`/`panelDark` 底色、13pt 基准字号（用户可调，整棵界面跟随）、圆角 7–9、分隔线 0.4 透明度、SF Symbols 图标。开源 MIT，公开仓库名 DeskNoteMac。

## Evidence on Hand

`README.md` 与 `docs/`；`--demo --shots` 的离屏截图基建（演示数据隔离在临时目录和独立偏好 suite，绝不碰真实数据）；现有 21 个 Swift 源文件构成的完整可用界面；`Sources/DeskNote/Vault.swift` 的文件层与一套只在 /tmp 里跑的往返测试电池。没有真实用户数据、用户量、评分或对比基准可用于演示——界面里的示例内容必须来自 `DemoData`，并在文档里说明是编的；这些一律不许编造成绩。

## Product Principles

1. 文件是真相，app 只是看它的一扇窗。任何界面状态都必须能从磁盘重建。
2. 用户的字不许被 app 改动或丢掉：读进来什么，写回去还是什么。
3. 高频动作零摩擦——一次点击、一格边条、一个热键，不弹层、不确认、不解释。
4. 破坏性操作要么显式确认、要么可撤销、要么进 trash，三者必占其一。
5. 新界面长在同一套约定上；看不出是同一个 app，就是失败。

## Accessibility & Inclusion

深浅色两套主题都要成立（底色、色块、选中态各有对应值，不靠单一背景假设）。字号由用户设定驱动，整棵界面按 `noteFontSize` 派生，不写死像素。键盘路径：⌘F 搜索、⌘1–4 切分区、Esc 退出搜索、⌘N 新建便签。纯图标按钮一律带 `.help` 说明。
