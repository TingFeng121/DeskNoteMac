# DeskNote 交接：库工作区、性能与 Obsidian 兼容

更新日期：2026-11-01。上一轮的结尾是「用户还是报卡」，那一轮把**同步层**改成事件驱动的路径索引；本轮把剩下的两半修完——正文不再常驻、解析有缓存，并把 Obsidian 那一套高级渲染（代码高亮 / Mermaid / 公式 / callout）用本地资源接进来了。见「『还是好卡』的第三轮」和「高级渲染」两节。

## 先看当前状态

- 已交付的应用支持文件树、Markdown 阅读/源码编辑/分屏、新建文件和文件夹、重命名、自动保存、内部链接与反向链接、按需深搜正文。
- 已交付透明度调整：主界面固定不透明，桌面组件与独立便签跟随原有透明度设置。设置项改为「便签与桌面组件透明度」。
- 回归测试现在是**五层**（vault / sync / library / tree / reader），373 项全绿；同步端到端自检 `--demo --vault-selftest` 到第 14 段。
- Base64 / Obsidian 图片兼容修复**已完成整体构建 + 真实出图 + 自检断言**，见「图片问题」一节；这一条不再是「待验证」。
- 用户报的「还是好卡」定位过三次。第一次是**同步在追自己写的 `state.json`**（一条约 5 秒一圈的自循环）；第二次是**每轮枚举整棵树**（213 份文件里占 39 ms / 96 ms），改成事件驱动的路径索引：每 0.4 秒那一轮 96 ms → **0.75 ms**；第三次是**库文档每存一次盘都整库重走**、**整库正文常驻内存**、**每敲一个字主线程全库重扫**，见「『还是好卡』的第三轮」：打字那一轮 190 ms → 0.3–0.74 ms，213 份库的常驻正文从「整库」降到 358 KB，重解析命中 0.0 ms。同步仍在主线程，但它已经不在交互路径上。
- **高级渲染已经接上，不再是草稿**：`Sources/DeskNote/LibraryRichReader.swift` 在 target 里、随 `.app` 打包的本地资源在 `MarkdownRenderer/`（40 个文件 / 6.2 MB，版本与 SHA-256 钉在 `MarkdownRenderer/VERSIONS.json`）。它**只在阅读模式**接管，编辑与分屏仍是原生 `NSTextView`；Mermaid、KaTeX 公式、代码高亮、callout 出自离线 vendor 的 markdown-it / DOMPurify / highlight.js / KaTeX / mermaid，`connect-src 'none'`，不联网。用户脚本、Dataview、Obsidian 社区插件 API **仍然没有**——能画 Mermaid 不等于能跑别人的插件，文案不许这么写。
- **本轮产物已装并在跑**（C2 装完再把实测数字补进「第三轮」末尾）。真实 `data.json` 的 md5 在自检前后一致（`2ba901a08545ff97f8c9fc86f7168796`），测试没碰过它。
- 工作区有大量原有及本轮未提交改动；没有 commit、push、PR。不要 reset、clean 或覆盖未跟踪文件。


旧交接已归档到 [此前 vault 交接](archive/HANDOFF-vault-before-workspace-2026-10-31.md)。其中「库只读」「表格与预览抽屉」「147 条测试」「已安装最新版」等描述属于旧状态，不应沿用。

## 用户意图与偏好

1. 保留 DeskNote 原生风格，基础工作流向 Obsidian 靠拢；用户明确选过「保留 DeskNote 风格，补齐 Obsidian 基础功能」。
2. 性能消耗要低，文件树点击收起不要延迟。真实库截图显示约 213 个 Markdown 文件，正文可能包含很长的 Base64 图片。
3. 主界面不透明，桌面组件和钉住的便签可透明。
4. 新反馈：嵌入图片无法阅读；希望文档解析、脚本/图表解析逐步靠近 Obsidian。
5. 「REA」明确指 [morluto/rea](https://github.com/morluto/rea) 的 reverse-engineer-anything 技能，**不是 React**。用户让评估能否用于复刻，不是要求把应用迁移成 React/Electron。
6. 用户希望快，不喜欢反复确认；已授权并行子任务，指定子 agent 为 **gpt-6-luna，reasoning_effort=max**。
7. 本轮已应用 impeccable 技能。已有 PRODUCT.md / DESIGN.md，界面继承原生配色、字号与布局规则；不要重新开展视觉方向选择。

## 项目与数据底线

- 项目目录：`/Users/tingfeng/Documents/AI PRJ/软件/DeskNote`。
- SwiftPM，macOS 14+，AppKit / SwiftUI，没有 Xcode 工程；构建入口 `build-app.sh`。
- 笔记是磁盘上的普通 `.md`；`data.json` 继续作为缓存。真实文件在 `~/Library/Application Support/DeskNote/`，不要拿真实数据跑测试、恢复或迁移。
- 带 DeskNote 身份的文件以 frontmatter 中的 id 识别；改名/移动不能丢身份。冲突副本不参与同一身份的同步。
- 元数据和正文空白应保留；保存前比对完整磁盘版本，外部同时修改/删除时保留原文件，把本次编辑另存副本。
- 删除的受管对象走 `.desknote/trash`；不要静默覆盖内容。
- WebDAV 密码只在钥匙串，禁止打印、写入偏好或命令行。不要代点钥匙串授权。
- 演示用 `--demo`，它使用临时目录和独立偏好。**不要并行运行两个 demo/selftest/shots 实例**：启动时会清理同一个演示库，互相干扰。
- 不代重启/点击用户真实应用。离屏截图只用演示实例；不要截全屏或注入真实热键。

## 代码地图

| 文件 | 职责 / 当前状态 |
| --- | --- |
| `Sources/DeskNote/Library.swift` | `LibraryModel`：跨轮的行集、过滤后的行、徽标计数、反向链接、后台扫描调度。正文不再常驻（见 `LibraryScan`），基线换成 `libraryBaseline.v2`（`[路径: FileStamp]`）。 |
| `Sources/DeskNote/LibraryScan.swift` | 纯 Foundation 的扫描层：`LibraryRow`（`head` 只留正文前 32 KB + `truncated` + 预算好的 `searchBlob`）、`LibraryScan.scan(...)`、`state(diskNewer:appNewer:)`。带 `previous:` 入参做增量：stat 没变的文件直接复用那一行，不重读。`run.sh library` 层链它。 |
| `Sources/DeskNote/LibrarySearch.swift` | 按需深搜：对当前 query 在后台分块流式读正文（可取消，块边界留重叠），命中回主线程并入行集。近文搜只看前 32 KB，更深处靠这一条。 |
| `Sources/DeskNote/LibraryWorkspace.swift` | 工作区、工具栏、命名弹窗、文档打开、阅读/编辑/分屏。树是独立子视图；阅读模式按 `LibraryRichReader.isNeeded` 分流到网页读者，编辑与分屏仍走原生。搜索框有防抖，深搜是一条显式动作。 |
| `Sources/DeskNote/LibraryFileTree.swift` | 文件树子视图，单独观察树的选中/折叠状态；目录点击不应使正文重新解析。 |
| `Sources/DeskNote/LibraryTreeIndex.swift` | 纯 Foundation 目录索引。预计算目录优先自然排序、标签、稳定 id、父节点和子树终点。 |
| `Sources/DeskNote/LibraryTreeState.swift` | 树独立的 Observable 状态。缓存可见节点；toggle 跳过折叠子树，搜索/筛选只在输入改变时计算祖先集合。 |
| `Sources/DeskNote/LibraryFiles.swift` | 文件读写、快照、frontmatter 原样保留、冲突副本、路径/软链安全。`inventory` 一次枚举返回目录和 Markdown，供后台扫描使用。 |
| `Sources/DeskNote/LibraryDocument.swift` | 文档会话、0.6 秒防抖保存、外部版本冲突保护、保存失败保留编辑。`open`/`refresh` 有 `FileStamp` 闸门；超过 `ReaderCache.synchronousLoadLimit`（2 MB）走后台装载，装载期间拒绝写盘；字数/行数随编辑增量更新。 |
| `Sources/DeskNote/LibrarySourceEditor.swift` | 原生源码编辑、高亮、撤销/重做、中文输入、Tab、⌘B / ⌘I / ⌘K。 |
| `Sources/DeskNote/ReaderParse.swift` | 纯 Foundation 的解析：`ReaderItem` / `CellAlignment` / `ReaderParse.parse(_:)`，含「攒够约 32 KB 就在行边界 flush」和 data-URI 限额。视图侧只剩画。`run.sh reader` 层链它。 |
| `Sources/DeskNote/ReaderCache.swift` | 按内容哈希的解析缓存（`NSCache`，`countLimit 24` / 24 MB，单条超 6 MB 不进缓存），配一个可取消的装载闸门；`synchronousLoadLimit` 也住在这里。 |
| `Sources/DeskNote/LibraryReader.swift` | 原生 Markdown 阅读与图片；`parse` 走 `ReaderParse` + `ReaderCache`，重解析期间继续画上一版快照。图片解码留在视图侧，`ReaderImageCache` 的 `totalCostLimit` 96 MB。 |
| `Sources/DeskNote/LibraryRichReader.swift` | **在 target 里、已接上**：WebKit 高级阅读器（只在阅读模式）。`isNeeded` 做按字节 + 按 (path, revision) 记忆的门；`RendererLocations` 三级找资源并在缺失时退回原生；`RichReaderImages` / `LocalImageSchemeHandler` 走 `desknote-image://local`，含库内包含检查与 48 MB 上限，SVG 屏蔽。 |
| `MarkdownRenderer/` | 离线前端：`index.html`（CSP：`default-src 'none'`、`connect-src 'none'`、无 `'unsafe-eval'`）、`renderer.js`、`renderer.css`、`vendor/`、`licenses/`、`VERSIONS.json`（每个文件的 SHA-256）、`NOTICE.md`。`build-app.sh` 整目录拷进 `Contents/Resources/`。 |
| `Sources/DeskNote/FileStamp.swift` | mtime/size/ctime 三点位，按整毫秒比。`VaultSync` 与 `LibraryDocument` / `LibraryScan` 共用这一个闸门。 |
| `Sources/DeskNote/Vault.swift` / `VaultSync.swift` / `VaultWatcher.swift` | 文件编解码、双向同步、FSEvents。`VaultSync` 里现在是三层：`FileStamp` → `VaultIndex`（跨轮的路径索引，`rebuild` / `update`）→ `sync(data:root:diskPaths:)` 三种模式（`nil` 整库重走 / `[]` 一个目录不走 / 有值只看报上来的几条）。监听器把防抖窗口里的事件路径攒成那份清单；库文档存盘只报自己那一条路径。只有 Foundation，能在 `run.sh sync` 里整条跑。 |
| `docs/OBSIDIAN_ARCHITECTURE.md` | REA 抽出来的 Obsidian 文件层/解析层形状，含证据出处、与 DeskNote 的逐项差距、四条边界和落地结果与实测数字。**这一份是同步层的施工图**；`OBSIDIAN_COMPATIBILITY.md` 是更早的适用性评估。 |
| `Sources/DeskNote/Windows.swift` | `applyNoteWindowTheme(_:allowsTransparency:)`：主窗口两处调用显式 false，组件与便签默认 true。 |
| `Sources/DeskNote/Demo.swift` | 隔离演示、离屏出图、同步与阅读端到端自检（第 1–14 段）。网页读者的图用 `takeSnapshot` 和窗口位图合成；没画完的图直接拒绝出，不拿占位画面充数。 |
| `docs/OBSIDIAN_COMPATIBILITY.md` | REA 适用性、已安装 Obsidian 的静态证据、兼容路线与未知项。 |

## 文件树延迟：已做的整改

旧实现每次重绘会在 ForEach 与空态判断中各调用一次 `entries(root)`：重新过滤和排序全部文件，排序比较器反复拆 URL 路径，收起时逐节点遍历全部 collapsed 前缀。`selectedFolder` 和 `collapsed` 由父工作区持有，目录点击还会连带重建右侧 Markdown / 图片视图。

现在：

- 排序与树构建在后台扫描时完成，界面只消费缓存索引。
- 为每个目录记录 preorder `subtreeEnd`，收起时一次跳过整段后代；不重新排序。
- 缓存可见节点、路径标签与 id；搜索匹配先算父目录集合，避免 folder × files 嵌套扫描。
- 折叠状态和新建目标目录一起放进 `LibraryTreeState`，由 `LibraryFileTree` 观察，避免只拆 collapsed 却仍通过 selectedFolder 刷新父视图。
- 目录枚举从 UI 主线程移走；`LibraryFiles.inventory` 一次返回目录/Markdown，避免分别遍历。
- 保持原行为：搜索/筛选时展开匹配项的祖先；同库刷新保留折叠状态；切库重置；打开文件展开其路径。

验证：`Tools/vault-tests/TreeLayer/main.swift` 有 35 项断言，覆盖目录优先自然排序、完整子树/深层折叠、搜索、空目录、toggle/reveal、同库更新保留状态、新库重置。

10,000 个合成文件的末次算法基准：旧算法每次 body 两遍、3 轮合计约 **6745 ms**；新索引一次初始化/排序约 **305 ms**；新折叠路径 3 轮合计约 **6.99 ms**。**这不是完整 UI 延迟或内存基准，不能把算法比值当成用户端到端提速。** 最新界面尚未真机点击或重新截图验证。

## 图片问题：已修并做完真实出图验证

截图里的失败是 `data:image/png;base64,...` 嵌入图片被当成无法读取的路径，并把巨大编码显示在界面。

最新 `LibraryReader.swift`：

- 支持 PNG/JPEG/GIF/WebP Base64 data URI。
- ImageIO 校验尺寸并生成最大 1800px 缩略图；对输入体积/像素数有限制。
- NSCache 缓存解码结果和失败结果，Base64 摘要在解析时生成。
- Markdown 解析快照改成后台任务，不在 body 每次重新解析。
- 支持 `![[路径]]` / `![[路径|300]]`，普通 Markdown 图片含空格/尖括号路径。
- 图片路径先查文档相对目录，再查库根相对路径，各自校验 root/软链边界；不在 UI 线程遍历全库找裸文件名。
- width 是 maxWidth，上限仍服从父容器；避免窄分栏被固定宽度撑开。
- Wiki embed 与普通图片匹配范围去重，避免重叠区间切片崩溃；代码区不转换。
- 失败只显示短提示，不再输出 Base64 或长地址。

**2026-10-31 验证结果（不再是「待测」）**：`--demo --shots` 出的 `library-images.png` 原图 2000×2240，上、下两半分别裁开看过，七类写法都对——大 Base64 画成图、`![[附件/格式示例.png|320]]` 按 320 画、同一行两张都出图、尖括号里带空格的路径出图、行内代码里的 `![...]()` 原样留在代码段、坏 data URI 和库外路径各自只给一句「图片无法显示」。另在 620×620 的分屏窗口截了一次，图片在约 300 pt 宽的阅读栏里不撑破边界。

**证据落在哪儿要说清楚**：仓库里 `docs/screenshots/library-images.png` 是从原图裁出的 1440×880，只覆盖「大 Base64 + `![[…|320]]`」两格；剩下几格的证据是那轮 `/tmp` 里的整张原图和下面这些断言，没有入库。要看全的请重跑一次出图。

验证过程发现并修掉一处：两张图之间那个空格会攒成一段空正文，`NoteBodyView` 于是把「空便签」占位画在两张图中间；`flushMarkdown()` 现在丢掉纯空白段。

同一轮把 `LibraryReader.parse` / `safeLocalImageURL` 从 private 放开到 internal，在 `--demo --vault-selftest` 里加了 13 条断言（图片语法 7 条 + root 边界 6 条，含「借软链绕出库外」）。出图只证明这一次截对了，断言才管得住下次改解析的人。

## 真正的「卡」：同步在追自己的尾巴（2026-10-31 22:45 实测定位）

用户报「还是好卡」时跑的就是本轮新装的包，所以这不是旧产物。对真实进程取样，证据如下：

- `top`：主线程 54.3% CPU，进程 257 MB。
- `sample <pid> 5`：主线程 **3331/3332** 个采样落在 `VaultWatcher.consume()` → `Store.pullFromVault()` → `VaultSync.sync()`，其中约 55% 在 `String.replacingOccurrences` 里做大小写折叠。隔 7 分钟再取一次，1530/1530 还在同一格。
- 用户的库是 `~/Documents/个人/obsidian`：**200 个 .md、整库 512 MB**。
- 决定性一条：`.desknote/state.json` 的 mtime 每约 5 秒前进一次，而同一时间窗内**没有任何 .md 被改动**（`find -newermt "-2 minutes"` 为 0）。

也就是说：同步每轮无条件重写 `state.json` → 这个文件就在被监听的库里 → FSEvents 报回来 → 再跑一轮同步。Obsidian 自己在 `.obsidian/workspace.json` 上的频繁写入用同一套机制放大。界面卡不是树或阅读器画不动，是主线程一直被这条循环占着。

三处改动（都有回归断言）：

1. `VaultSync.sync` 结尾改成 `state != loaded` 才落盘。SyncLayer 加了 3 条：静默一轮 mtime 不变、报告为空、**真有改动时仍必须落盘**（防止有人拿「不写」当省电把功能改没）。
2. `VaultWatcher` 按事件路径过滤：`.desknote/` 与 `.obsidian/` 不触发防抖，`kFSEventStreamEventFlagMustScanSubDirs` 一律放行。口径放在 `VaultSync.isBookkeeping(_:root:)`（只有 Foundation，可测），和 `Vault.markdownFiles` 的 `skipsHiddenFiles` 是同一套范围。SyncLayer 加了 5 条，含「`.desknote-x` 这种名字像的别误杀」和「库外的路径不在这个口径里」。
3. `Vault.readFrontmatter` 只读文件头 64 KB（新增 `Vault.readHead(of:limit:)`），正文再大也不再整篇读进来跑三遍 `normalize`；开头不是 `---` 就直接返回 nil，文件头里等不到收尾栅栏才退回整篇读。VaultLayer 加了 5 条，含一份 4 MB 正文的便签仍认得回 id、CRLF 属性照旧能读。

**尚未做**：把同步挪出主线程。修完 1-3 之后一轮同步只剩 200 次小文件头读 + 哈希，但仍然是主线程。Obsidian 的做法（内存索引 + 按 (size, mtime, editCount) 失效 + 后台分批解析）见 [OBSIDIAN_ARCHITECTURE](OBSIDIAN_ARCHITECTURE.md)，那才是这一层的最终形态。

> 2026-11-01 更新：这一层按那份架构重排完了，见下一节。「挪出主线程」这一步现在看不需要做了——每 0.4 秒那一轮已经掉到 0.75 ms，先实测再说。

## 「还是好卡」的第二轮：整库重走换成了事件清单（2026-11-01）

用户还是报卡。这次先量，不先改。SyncLayer 第 21 节按真实库的形状造了一份（213 份 .md + 一张 0.8 MB 内联图便签），一轮拆开是：

```
整库重走 96 ms ＝ 枚举 39 ms ＋ 逐份 stat 2.7 ms ＋ App 侧哈希 0.5 ms ＋ 其余
```

上一轮的三项整改把「读正文」省掉了，但**枚举整棵树每轮照付**，而它一次同步里最大的一项。这就是 Obsidian 把它做成常驻 `FsCache`、只按事件路径更新的原因（[OBSIDIAN_ARCHITECTURE §2–§3](OBSIDIAN_ARCHITECTURE.md)）。

改动三处：

1. `VaultIndex` 从「这一趟看过哪些文件」的临时账，变成跨轮的**路径索引**：`rebuild(root:)` 整库重走、`update(paths:root:)` 只处理报上来的路径（目录事件重走那一层，消失的路径连带掉它下面所有格）。`FileStamp = {mtimeMs, size, ctimeMs}`，时间**按整毫秒**比——`timeIntervalSinceReferenceDate` 在这个量级上，一次「贴回原时间再读出」的往返就会在第 7 位小数上对不上，裸 Double 判相等等于把没动的文件读成动了的，闸门白装。
2. `VaultSync.sync` 的入参 `full: Bool` 换成 `diskPaths: [String]?`：`nil` 整库重走（冷启动 / 换库 / `MustScanSubDirs`）、`[]` 一个目录也不走（每次存盘）、有值只看那几条（监听器）。`VaultWatcher` 在防抖窗口里把事件路径攒进 `pending` 一并交出去；`Store.pushToVault` 传 `[]`。
3. 写出去 / 搬进 trash / 存成冲突副本的这些路径，同步更新那本账（`settle`、`move`、`stashConflict`），不然下一轮拿一条已经指向别处的路径的旧 stat 做判断。

顺带一处：`Vault.hash` 的十六进制编码从 `map { String(format: "%02x", $0) }.joined()` 换成查表，全库重读 13.3 ms → 7.0 ms。

结果（同一份基准，`run.sh sync` 会打印）：

| 一轮 | 改前 | 改后 |
|---|---|---|
| App 侧（打字时每 0.4 s 一次） | 96 ms | **0.75 ms** |
| 400 份 .md 的同一轮 | 190 ms | **0.3 ms** |
| 整库重走 | 每轮都付 | 只在冷启动 / 漏事件付 |

回归：SyncLayer 从 94 → **116** 项，含「换字不换字节数且贴回 mtime ⇒ 常规一轮认不出（明码标价的代价）」「`diskPaths: nil` 必须认出来」「新增一条记一格、删一条掉一格、别的文件一格没动」「整个子目录搬走 ⇒ 账下它的全掉，报新目录再全认回来」「老 state.json 没 stamp 那格照样读得回来，读完补上」。`--demo --vault-selftest` 加了一条走事件清单的采纳。

**这一步买到的和丢掉的**：`[]` 那一轮只是**不走目录树**，不是不看磁盘——每个 DeskNote 自己对象的那份文件仍然每轮 `FileStamp`，所以「外部编辑器改了我们的便签」这种改动，一条事件都没收到也照样会在下一次存盘那一轮被认出来并采纳。真正依赖事件清单的是**身份发现**：外部新建的一份带 `desknote.id` 的文件、或者被改名/挪走的那一份，在漏事件（且没收到 `MustScanSubDirs`）的情况下会看不见，直到下次启动、库页手动刷新或那条路径自己被事件报上来。以前每轮重走整库把这两种都覆盖了，代价是每次存盘 96 ms。
**下一步是实测确认，不是继续重构**：真实应用重启后，对真实库（`~/Documents/个人/obsidian`，200 份 .md / 512 MB）取 `sample` 若干秒，确认 `VaultSync.sync` 不再占据主线程采样；同时看 `LibraryModel.rescan` 与阅读器的 `parsing` 计数还剩多少。只有在实测仍见卡时才考虑把 `sync` 搬去后台线程——那要处理 `data` 快照与合并，风险大于现在看得见的收益。


## 「还是好卡」的第三轮：正文常驻与解析缓存（2026-11-01）

第二轮修完同步层，用户还是报卡。这一轮先读源码定位，不先改。剩下三个卡点都不在同步里，而且都长在用户天天按的那个动作上：

| # | 卡在哪 | 触发频率 |
|---|---|---|
| 1 | 库文档每存一次盘都**整库重走**（`LibraryDocument.save()` 调 `pullFromVault()`，它默认 `diskPaths: nil`） | 每敲 0.6 秒一次 |
| 2 | 整库正文**常驻内存** + 每敲一个字主线程全库 `lowercased()` 重扫 | 真实库 512 MB / 200 份 |
| 3 | 存盘后**再读一遍整篇**，每轮扫描后又读一遍 | 与 1 同频 |

八步，每步都有回归断言：

- **A1 三处 `pullFromVault()` 传路径**。`save()` 传 `[url.path]`（文件刚被 `LibraryFiles.save` 换过 inode，报上去正好刷新索引那格），改名那条传 `[旧, 新]`；冷启动、换库、`MustScanSubDirs` 三处保留 `nil`。SyncLayer §22 断言「改名对 ⇒ 旧路径掉账、新路径认回 id、其余一格没动」；selftest 用 `VaultIndex` 计数前后差断言 `save()` 进不了 `index.rebuild`。
- **A2 `open` / `refresh` 的 stat 闸门**。`LibraryDocument` 记一个 `stamp: FileStamp?`，一模一样直接返回，断掉「存盘 → rescan → `lastScan` 变 → 整篇再读」那条尾巴。`save()` 里那次整篇重读也加了闸门：只有同步真在磁盘上动了元数据（`adopted` 或 `written` > 0）才重读，否则磁盘字节可证明等于 `snapshot.prefix + text`，直接用它摆好基线。
- **A3 扫描增量化 + 正文不再常驻**。新建只有 Foundation 的 `LibraryScan.swift`（`LibraryRow` / `scan` / `state`），`previous: [String: LibraryRow]` 按标准化路径复用行，stamp 没变的连读都不读；行里只留 `head`（前 32 KB）+ `truncated`，`searchBlob` 在后台一次算好。基线从 `LibraryModel.Signature` 换成 `[String: FileStamp]`、持久化键改 `libraryBaseline.v2`（旧键不再读，首轮全 `.clean`，正是原有的冷启动语义）。213 份的基准（`run.sh library` 会打印）：冷启动 224.7 ms → 增量轮 51.9 ms，其中枚举 2.8 / stat 0.6 / 路径标准化 5.3 ms；**行上常驻 358 KB，磁盘正文 1295 KB**。
  **明码标价的回归**：超过 32 KB 的正文不再能被随手搜到——由 A5 那条显式动作补，不是悄悄少搜。
- **A4 搜索防抖 0.2 s**：`query` 不再直连过滤，`debouncedQuery` 由 `.task(id: query)` 延一拍赋值。
- **A5 按需深搜**：`LibrarySearch.swift` 在后台**分块流式**读正文（块边界留重叠，跨块的那个词不漏）、可取消，搜索框下面一条「搜正文深处」明说它比近文搜慢。基准：20 份 / 7 MB 27.2 ms，全程不整篇驻留。
- **A6 阅读层缓存**：`ReaderParse.swift`（纯解析，不带 SwiftUI / AppKit，所以能进 `run.sh reader`）+ `ReaderCache.swift`（`NSCache`，键是**内容哈希**，`countLimit 24`、`totalCostLimit` 24 MB）。改名 / 移动 / 重开同一篇 ⇒ 命中，不重解析。基准：1796 KB 冷解析 157.5 ms → 命中 0.0 ms；9 MB 那份整篇 734 ms，**超过 6 MB 的条目根本不进缓存**（否则缓存就是把 512 MB 变成常驻 RAM 的那只手）。大文档 `open` 走后台装载（>2 MB），装载期间 `edited()` / `save()` 一律拒绝——这条同时是数据安全闸门：磁盘基线没到之前不许键盘写盘。
- **A7 渲染路径上的 O(n)**：`body` 里那两次整串比较 / `trimmingCharacters` 换成内容哈希与一次算好的标志；状态栏的字数行数挂在 `LibraryDocument` 上随防抖刷新；`flushMarkdown()` 攒够约 32 KB 就在行边界切一段，`NoteBodyView` 再也不会为一整篇 30 MB 字符串阻塞。
- **A8 证明折叠不重解析**：`ReaderCache.misses` 与 `LibraryReader.parsing == 0` 两道闸门。selftest 里开一篇大文档 → 收起一个目录 + 折叠侧栏 → 泵 0.3 s ×3 → 命中数增量必须为 0；`parsing != 0` 时报「测量无效」而不是「通过」。

**与计划的三处偏离**（都是看过代码之后改的，不是漏做）：① 没建第三个 `NSCache` 存 base64 字节——解析结果里只留摘要，超 6 MB 的条目整个不缓存；② 计划里的 L1「路径 → (stamp, 哈希)」删了，行上已经有 stamp，两本账必然对不齐；③ A8 那个单调计数器 `parseStarted` 没加，`ReaderCache.misses` 回答的是同一个问题。

## 高级渲染：本地资源接进来了（B 阶段，2026-11-01）

`LibraryRichReader.swift` 从 `docs/drafts/` 回迁进 target，草稿那 4 处编译错误（三处 `webView.scrollView.*` 是 UIKit 属性、一处写 `private(set)`）已按 macOS 的写法改掉，现在是 `underPageBackgroundColor` + 由 `{action:'ready'}` 回调置位的 `rendererReady`。

**资源**：`MarkdownRenderer/` 在仓库根，40 个文件 6.2 MB，全部取自官方 npm tarball、逐个核对 registry 的 sha512，每个落盘文件的 SHA-256 记在 `VERSIONS.json`，许可证在 `licenses/` + `NOTICE.md`。钉死的版本：markdown-it 15.0.3、markdown-it-footnote 4.0.0、dompurify 3.4.17、@highlightjs/cdn-assets 11.12.0、katex 0.19.1（只带 woff2，省 0.8 MB）、mermaid 12.2.0。`build-app.sh` 把整个目录 `cp -R` 进 `Contents/Resources/`；**没给 `Package.swift` 加 `resources:`**——这个 .app 是脚本手装的，SwiftPM 的 bundle 根本不会被拷出去，加了反而是第二条路。查找走三级：`Bundle.main.url(forResource:withExtension:subdirectory:)` → `Contents/Resources/MarkdownRenderer` → DEBUG 下按仓库根定位（这条覆盖自检和出图直接跑裸二进制那种形态）。

**分流**：`LibraryWorkspace` 只在**阅读模式**且 `LibraryRichReader.isNeeded(text:revision:path:)` 为真时起网页读者；编辑、分屏、普通文档全是原生。`isNeeded` 是一次字节扫（`$`/`$$`、```` ```mermaid ````、`~~~`、`[^`、`> [!类型]`、行首原始 HTML），按 (路径, revision) 记忆，不做任何「读一遍正文」的事。**普通代码栅栏故意不分流**——原生读者画 `<pre>` 没问题，为它起一个 WebKit 不值。勾选任务 `- [ ]` 也留在原生，那是便签那边共用的语法。

**几条只能靠实测才知道的结论**（都写进了自检，改资源前先读这里）：

1. **CSP 不需要 `'unsafe-eval'`**：`script-src 'self'` 就能让 mermaid 12.2.0 画出 SVG。`index.html` 里是 `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' desknote-image: data: blob:; font-src 'self'; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'`。
2. **被 CSP 拦掉的外链仍然留一条记账**：WebKit 在 `performance.getEntriesByType('resource')` 里给它 `dur=0 bytes=0 status=0`。所以「离线」不能按条目存在与否断言，只能按响应信号断言——自检那一条就是这么写的，实测打印 `img https://example.invalid/a.png dur=0 bytes=0 status=0`。
3. **`desknote-image://local` 的百分号编码只解一次，且只解 `target`**：markdown-it 对目的地做过 `encodeURI`，renderer.js `tryDecode` 后再 `encodeURIComponent` 一次，`URLComponents.queryItems` 解一次，Swift 侧再对 `target` 解一次（那是作者手写的转义，和原生 `safeLocalImageURL` 同口径）；`note` 不许多解一遍。
4. **图片是 `loading="lazy"` 的**：压在 1200 行正文底下的那张不滚就不发请求——这不是缺陷。自检要量「字节真从自定义 scheme 回来了」，所以按用户的方式先 `scrollIntoView()`。
5. **出图路径变了**：`cacheDisplay` 对 `WKWebView` 只留一个同尺寸的洞（画面在 WebContent 进程里合成），所以 `--demo --shots` 现在是「窗口位图 + 单独向网页读者 `takeSnapshot` + 按坐标贴回」。而且**必须等字体和动画**：`document.fonts.status != 'loaded'` 时截回来的是公式空着、Mermaid 只剩半截节点的图。等不到就明说 `fail` 并**不写这张图**，不能拿占位画面当验收图。
6. **降级**：`RendererLocations.isComplete` 缺任何一个文件就整个不用，直接退回原生读者（不是白框）。自检里打一枪：把目录指到一个少一个文件的位置，判出来的必须是 false。

**内存实测**（selftest 第 14 段，量的是本进程 `phys_footprint`）：十次「同一个网页读者换下一篇」（每篇 1200 行正文 + 两段公式 + 两张 Mermaid + 一张库内图），第 2 轮 417 MB → 第 10 轮 416 MB，**增 0 MB**；拆掉读者静置 4 秒仍 0 MB。上一版这里量的是「十轮挂上/拆掉」，那是 1.5 MB × 10 的壳子钱，跟用户怎么用没关系——所以换成了换篇。

**自检里那一堆断言**（`--demo --vault-selftest` 第 12–14 段）：分流真值表 9 例、资源完整性、CSP 静态核对、`RichReaderImages` 与 Swift 侧口径一致，然后是真在 WebKit 里画一遍：`bridge=function`、`math 2`、`callout 1`、`mermaid svg 1`、`table 1`、`hljs 1`、`image 1`、`link 1`、`footnote 1`、`xss 0`、`pwn undefined`、`inlineScript 0`、`external 0`、`badLink 0`、`overflow 0`。

## REA：评估与实现都已落地

**2026-11-01 更正**：下面这一段写的是「跑不了 REA」，已经过期——用户给了仓库地址之后环境搭起来了，真实跑过一次，证据与结论在 [OBSIDIAN_ARCHITECTURE](OBSIDIAN_ARCHITECTURE.md)。**这份文档里凡是写「没有 Evidence ID」的地方都以那份为准。** 同一句「实现未完成」也不成立了：资源、接入、安全/离线/降级/出图都在上一节，`docs/drafts/` 已经空了。

- 环境：本机没有 npm，`node` 只有 Qoder 的 shim（v24.18.0，低于 REA 6.8.0 要求的 24.22.1）。Node 24.22.2 与 `rea-agents` 都装在 `/tmp/rea/` 下，**没有动系统 PATH、没有装运行时、没有注册全局 MCP**。
- 产物：Evidence bundle `/tmp/rea/evidence/obs-index`，evidence id `ev_0d07d41f…154b8`，provider `rea-javascript-application`，`authority: shipped-artifact`。
- 两个必须记住的坑：整个 asar 一次跑会静默失败（`lib/` 14 MB 把 `max_semantic_nodes_per_file = 20000` 吃满），所以要 `--source-path` 挑文件；`recover-javascript-sources` 用不了（Wakaru 只发 Linux x64），所以下面的引用全是压缩后原文，按**保留的字符串常量和属性名**读，行号没有意义、只有字节偏移。
- REA 自己的限制：静态解析，「bundle bootstrap code was never executed」——看到的是代码写了什么，不是跑出来的行为。

目标是保留原生外壳、树、文件与源码编辑；普通文档继续原生阅读。复杂 Markdown 使用一个按需创建、切文档复用的 WKWebView，成熟 Markdown parser、代码高亮、公式和 Mermaid 资源离线加载，不为每个块/卡片创建 WebView。不引入完整 Electron，也不让 REA 随用户应用常驻。

当时停在这六个缺口，现在逐条对账：

| 缺口 | 现在 |
| --- | --- |
| 1. 草稿在 `docs/drafts/`，4 处编译错误 | **已改掉并回迁** `Sources/DeskNote/LibraryRichReader.swift`；`docs/drafts/` 空了。 |
| 2. `MarkdownRenderer/` 不存在 | **已在仓库根**，40 个文件 6.2 MB，`VERSIONS.json` 记 SHA-256。 |
| 3. 工作区没引用 `isNeeded` | **已分流**：只在阅读模式、只在那几类语法上起网页读者。 |
| 4. 打包没有资源逻辑 | **`build-app.sh` 已 `cp -R`**；`Package.swift` 故意不加 `resources:`。 |
| 5. 用户脚本 / Dataview / 社区插件 | **仍不做**。Mermaid 与代码高亮不等于执行任意 JS，README 与本文都不许写成插件兼容。 |
| 6. 没有 DOM / 安全 / 离线 / 快照测试，没有内存基准 | **都有**：自检第 12–14 段 + `--demo --shots` 的 `library-rich.png` + 十次换篇 0 MB。 |

依赖获取那阵子 npm registry / unpkg / jsDelivr 的 shell HTTPS 全超时，所以当时只把 highlight.js 11.11.1 与 DOMPurify 3.2.7 读到工具会话里、没落盘。**这一轮走的是官方 npm tarball + registry sha512 核对**，版本以 `VERSIONS.json` 为准（dompurify 3.4.17、highlight.js 11.12.0、KaTeX 0.19.1、mermaid 12.2.0）——上面那段旧记录里的版本号只是当时没下成的那批，别拿它当现状。仍然守住的约束：不复制 Obsidian 私有 bundle 当运行依赖。

## 验证与构建的准确范围

| 检查 | 结果与范围 |
| --- | --- |
| 五层回归 | 2026-11-01 `./Tools/vault-tests/run.sh all` 全绿：Vault 66 + Sync 134 + Library 97 + Tree 35 + Reader 41 = **373 项**。全是 Foundation / Observation 层，不验证 WebKit 或 SwiftUI 视图——那两样靠下一条。 |
| `--demo --vault-selftest` | **SELFTEST OK**（第 1–14 段，含 12 分流真值表 / 13 真起 WebKit 画一遍 / 14 十次换篇内存）。跑前跑后真实 `data.json` 的 md5 都是 `2ba901a08545ff97f8c9fc86f7168796`，没被碰过。 |
| `--demo --shots` | 16 张全出，`library-rich.png` 是「窗口位图 + 网页读者 `takeSnapshot`」合成的，看过原图：callout、Mermaid 三节点、KaTeX 公式、高亮代码、表格带内链都在。裸 debug 二进制跑完会在 `SettingsView` 那个通知异步任务里 `abort`（`bundleProxyForCurrentProcess is nil`）——没有 .app bundle 的固有现象，发生在 16 张全部写完之后；用打包 app 跑就没这条。 |
| 构建 | `swift build` 通过；`./build-app.sh`（arm64 + x86_64 + 签名）与 `codesign --verify --deep --strict` 见下一行，本轮收尾时跑。 |
| 已交付 app | 上一轮装的是 `/Applications/桌面便签.app`（09:51 那份，只到同步层）。本轮产物待 C2 重装，装完把实测数字补进「第三轮」一节末尾。 |
| 界面截图 | `library-rich.png` 是本轮新增；其余九张 `library-*.png` 仍是 10-31 22:55 那批（这一轮没改界面），`board / notes-editor / notes-gallery / panel / sticky` 是 10-21 那批。 |

接手后按依赖顺序做，别同时启动演示命令：

```sh
# 先处理未完成 RichReader 草稿，再验证最终源码能否编译
swift build -c debug

# 文件与树回归（tree 项含非阈值性能输出）
./Tools/vault-tests/run.sh

# 同步/文档会话端到端，先运行完再出图
.build/debug/DeskNote --demo --vault-selftest

# 完成资源与功能验证后再打包，避免发出半成品
./build-app.sh
codesign --verify --deep --strict build/桌面便签.app
build/桌面便签.app/Contents/MacOS/DeskNote --demo --shots /tmp/desknote-review
```

裸 debug 二进制跑 `--demo --shots` 会在**全部图都写完之后**从 `SettingsView` 那个等通知权限的异步任务里 `abort`（`NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`，退出码 134）。原因是这个二进制没有 `.app` bundle，`UNUserNotificationCenter` 拿不到代理。图片本身不受影响，但**别把这条当成 shots 失败去追**；要干净的退出码就用打包好的 app。原有离屏截图逻辑创建 HostingView 后马上缓存；新阅读器使用异步 task，WebKit 也需要加载时间，**应等待实际解析/DOM 就绪再截**，不能把加载占位画面当验收图。这一条本轮已经落地：`LibraryReader` 挂了 `@MainActor static var parsing` 计数，`shot(parse:)` 在窗口挂上去之后空转到计数归零才缓存位图——不加这个等待，每张阅读图截到的都是「正在读取文档…」。高级阅读器也接进来了，但它不能靠这个信号：`cacheDisplay` **截不到 `WKWebView`**（内容在 WebContent 进程里），所以先向页面要一份读数（`title` / `math` / `mermaid` / `callout` / `image` / `pending` / `fonts`），等到动画归零、字体 `loaded` 且标题真是这一篇，再用 `takeSnapshot` 取那一块，和窗口位图合成。读数拿不到或没画完就打 `fail` 并跳过这张，不出图。

## 后续建议顺序（需用户要求继续）

1. ~~审查/隔离未完成 RichReader 草稿，先让基础库源码可整体编译。~~ 已完成：草稿回迁进 target 并改掉那 4 处错误，`docs/drafts/` 已空。
2. ~~真实机器验证这一轮的索引改造~~ **已完成（2026-11-01 09:51，用户让 Agent 自己结束进程并重启）**，真实库 `~/Documents/个人/obsidian`（200 份 .md / 512 MB）：
   - 旧包（pid 9634）`sample 4`：主线程 2172 个采样，全部落在 `completeTaskWithClosure → … → VaultSync.sync(data:root:)` 那条链上，`markdownFiles` 在里面。
   - 新包（pid 43092，`nm` 里能查到 `diskPaths` 那份）静置 `sample 5`：**主线程 3938/3938 全部停在 `_BlockUntilNextEventMatchingListInModeWithFilter`，一个 `VaultSync` 帧都没有**；`top` 即时 0.0% CPU、206 MB。
   - `.desknote/state.json` 的 mtime 停在启动那一刻（09:51:30），静置 45 s 没有再前进。启动那一次是升级后的首轮：老 state.json 没有 `stamp` 那格，要整库补一遍基线，这是唯一一次全额。
   - 退出走的是 AppleEvent `quit`（`applicationWillTerminate → Store.flush()`），`data.json` 前后 md5 一致、mtime 没变——没有待落盘的改动。
   所以「把 `sync` 搬去后台线程」这一条**不做**：实测已经看不见主线程被占，剩下的整库重走只在冷启动与漏事件发生。
3. ~~验证文件树收起不触发右侧大文档重新解析~~ **已完成**：靠 `ReaderCache.misses`（不是 `parsing`，那个在并发下会说谎）加一次折叠/收起后的 `parsing == 0` 断言，重开同一篇增量 0，见「第三轮」A8。
4. ~~把 Base64 / wiki 图片修复做完真实渲染验证，再打包形成稳定交付点。~~ 已完成，见「图片问题」一节。
5. ~~再补成熟 parser 的高级预览资源与单实例生命周期~~ 已完成，见「高级渲染」一节：离线资源、单实例复用、高亮 / Mermaid / 公式 / callout / HTML 清洗 / 内部链接 / 离线与降级断言 / 真实出图 / 十轮换篇 0 MB 增长。
6. ~~更新 README / PRODUCT / DESIGN 到实际实现范围~~ 本轮跟完：README 的库章节改成 `diskPaths` 三档口径 + 深搜 + 高级渲染写实，`library-rich.png` 是真实合成图；HANDOFF、PRODUCT.md、DESIGN.md、[OBSIDIAN_ARCHITECTURE](OBSIDIAN_ARCHITECTURE.md) 的「不做」清单同步。**内存/CPU 的实测数字要真机采样，不许只报算法时间**——写在「第三轮」末尾和「已交付 app」那行的都是跑出来的。
7. ~~需要正式 REA 分析时再建立可用运行环境。~~ 已完成，见「REA 与高级 Markdown」一节顶部的更正：环境在 `/tmp/rea/`，跑过真实一次，证据 id 与两个坑都记在那里。要再跑一次时命令直接抄 [OBSIDIAN_ARCHITECTURE §0](OBSIDIAN_ARCHITECTURE.md)。
8. ~~边界 3（解析层两级缓存 + 串行队列，[OBSIDIAN_ARCHITECTURE §9](OBSIDIAN_ARCHITECTURE.md)）没开工。~~ 已开工并结掉，见「第三轮」A6/A7。与实现的两处偏差记在那里：按内容哈希的 L2 一把命中了「重开/改名/移动」，所以 L1（路径 → stat → 哈希）没有单独留一本账；Base64 也没有第三个 `NSCache`——单条超 6 MB 直接不进缓存，比再架一层更省。
9. 还没做的两件，都是明确留下的洞，不是漏掉的：**冷启动那一轮仍整库全额**（`diskHash(full:true)` 即使索引刚报「stat 没变」也逐份重读全文，改成 `verifyByStat` 是独立一笔，用户没报开机卡就先不做）；**大小写不敏感卷上只改大小写的改名**会留旧格，同一个 id 两处，现在由 `report.problem`「有两份文件」横幅兜住。用户脚本、Dataview、社区插件 API 不在范围内。

交接时已停止仍在运行的实现子 agent；没有继续修代码、构建、安装或启动用户应用。
