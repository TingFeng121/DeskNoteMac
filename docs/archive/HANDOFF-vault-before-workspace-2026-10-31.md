# 交接：DeskNote 的 Markdown 知识库（vault）

日期：2026-10-31。这一轮把「文件优先的知识库」从设计做到了能跑、能测、能装。
读这一篇就够了接着干，不必翻聊天记录。

## 0. 一分钟版

- 需求：像 Obsidian/Typora 那样直接读写 .md，实现知识库管理；用户会在外部编辑器里改文件，所以是**双向同步**。
- 边界（用户当场拍过的）：这一期做「同步 + 自己那份的读写 + 浏览与检索」；`[[双链]]`/反向链接**只读**；不接管库里别人的 .md（它们是「外部文档」，列出来、能预览，不写）。
- 入口：主窗口边条第 5 格「库」（⌘4），构图是文件工作台：过滤 chip + 五列表格 + 296pt 预览抽屉。
- 现在的状态：**引擎、UI、迁移、事件流、测试、README 全绿**。真机上还差的只有「第一次按建库」这一步——那一步必须用户自己按，见第 6 节。
- 复现验证：`./Tools/vault-tests/run.sh`（147 条断言）和 `build/桌面便签.app/Contents/MacOS/DeskNote --demo --vault-selftest`（19 条端到端）。

## 1. 代码地图

| 文件 | 归它管的事 |
|---|---|
| [Sources/DeskNote/Vault.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/Vault.swift) | 文件层：目录布局、文件名安全化、frontmatter 编解码、便签/待办板往返、`[[链接]]` 解析、枚举。只有 Foundation + CryptoKit。 |
| [Sources/DeskNote/VaultSync.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/VaultSync.swift) | 同步引擎：三方比对、写盘/采纳/冲突副本/回收站。只有 Foundation，所以能不带 SwiftUI 整条测一遍。 |
| [Sources/DeskNote/VaultWatcher.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/VaultWatcher.swift) | FSEvents 挂库目录，0.2s 合并 + 0.5s 防抖，收到事件就 `Store.pullFromVault()`。单独成文件是为了让上一层保持无 AppKit。 |
| [Sources/DeskNote/Store.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/Store.swift) | `save()` 拆成 `writeJSON() + pushToVault()`；`pullFromVault()`、`replaceFromVault()`、`vaultReport`、`mirroring` 防回环。 |
| [Sources/DeskNote/Library.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/Library.swift) | 库页 + `LibraryModel`（扫描、过滤、建库、指目录、双行横幅）。 |
| [Sources/DeskNote/Demo.swift](file:///Users/tingfeng/Documents/AI%20PRJ/软件/DeskNote/Sources/DeskNote/Demo.swift) | `AppEnv`（`--demo` 把数据和库都挪进临时目录）+ `VaultSelfTest`（`--demo --vault-selftest`）。 |

## 2. 磁盘上长什么样

```
<vault>/
  notes/<首行>-<id8>.md              一张便签一个文件
  <类别>/<项目>-<id8>.md              一块待办板：- [ ] 标题 📅 2026-11-02 ^<完整 UUID>
  .desknote/state.json               同步基线（本地状态，Obsidian 看不见）
  .desknote/trash/                   App 里删掉的对象搬来这里，不直接抹掉
```

三条硬规矩，改代码前先记住：

1. **身份是 frontmatter 里的 `desknote.id`，不是文件名。** 于是 Typora/Obsidian 改名、挪目录、整库搬家都还认得回来（测试第 8 组）。
2. **`state.json` 是「库建起来了」的唯一凭据。** 目录存在不算——iCloud 会先建空壳，用户也会自己 mkdir。没 state.json 时同步层一次文件 IO 都不做。
3. **路径一律先 `VaultSync.canon()`（解软链）再比对。** `/var` 是 `/private/var` 的软链：自己拼的串带 `/var`、枚举回来的是 `/private/var`，混用会把「没改名」读成「改了名」，`retire()` 会把刚写好的那份正文搬进回收站。这是这一轮真踩到的坑。

## 3. 同步的判定（三方比对）

第三方是 `state.json` 里每个对象的两格哈希：`diskHash`（上次看到的磁盘那份）、`appHash`（上次落盘时 App 这一份）。

| 磁盘动了 | App 动了 | 结果 |
|---|---|---|
| — | — | keep：什么都不做（自动备份靠这一格判断要不要跑） |
| — | ✓ | write：以 App 为准写出去 |
| ✓ | — | adopt：采纳磁盘那份进内存 |
| ✓ | ✓ | conflict：**先把磁盘那份另存成 `xxx 冲突 2026-10-31 09.12.33.md`**，再按 App 写正文 |
| 文件没了 | 任意 | write：补回来 |

几条不显眼但别改回去的判断：

- **外部删除不当删除处理。** 同步盘抽一下、iCloud 占位没落地，在真实机器上天天发生；当成删除就会白丢一整张便签。App 里删才算删（进 `.desknote/trash`）。
- **读不出 id 的文件不许采纳。** `Vault.readNote` 对非 UTF-8 会损失解码后合成一张**空**便签，照单采纳等于抹掉正文。现在要求 `parsed.id == id`，否则报 problem、原文件一个字不动（测试第 13 组）。
- **冲突副本不参与身份识别**（`Vault.isConflict`）：它带着同一个 id，算进来就跟正文那份抢身份，两轮之间来回漂移。
- **副本存不下就不写。** `stashConflict` 失败时直接跳过这个对象并报 problem——覆盖在前、保存在后就是丢内容。同一秒撞名会加 `-2`。
- **采纳只覆盖会进文件的字段**：`pinnedToDesktop` / `collapsed` / `expandedHeight` 是本地状态，整块换掉会把用户钉好的便签弹离桌面。
- **`appHash` 里 Deadline 只比「哪一天」**，因为文件里就是天粒度（Obsidian Tasks 约定）；拿带时刻的值比，写完再读回来永远不相等，会无限自写。
- **待办板写盘时，磁盘上已有的 `.text` 行按位置留着**，事项按 id 对位替换，App 新增的追加在后面。用户在 Obsidian 里加的说明段、表头不许蒸发。
- **改标题不重命名文件。** 否则每敲一个字就产一份回收站。文件名只在对象新建那一刻由首行决定。

## 4. 一次性迁移（#22）

`LibraryModel.createLibrary()` → `VaultSync.migrate(data:root:)`：以 App 为准把现在的所有便签和待办板写成文件并生成 state.json，**data.json 不删**，退成缓存。写完拿 `state.files.count` 和「便签数 + 板数」一比，对不上就在横幅里说「有几份没写出去」（目录只读、满了）。
`chooseDirectory()`（指一个已有文件夹）走 `sync`：对得上 id 的采纳进来，对不上的写出去，state.json 一落同步层就开工。

**这一段还没在真实数据上跑过**——用户机器上 `~/Library/Application Support/DeskNote/data.json` 是真工作笔记，不能替他们点。第一次建库由用户自己在「库」页按。

## 5. 验证怎么跑

```sh
./build-app.sh
./Tools/vault-tests/run.sh          # VaultLayer 61 + SyncLayer 86
build/桌面便签.app/Contents/MacOS/DeskNote --demo --vault-selftest   # 19 条，含真 FSEvents
```

- `Tools/vault-tests/run.sh` 把 `Sources/DeskNote/{Model,Vault,VaultSync}.swift` **符号链接**进临时目录再 `swiftc`。用符号链接是因为 `/tmp` 里的拷贝曾经悄悄过期过一次，测的和发的不是同一份代码。不进 `Package.swift` 的 test target：这个包只有一个 `.executableTarget`，6 行脚本就够，旧 toolchain 也能跑。
- `SyncLayer/shim.swift` 顶掉 `AppEnv`（真 AppEnv 在 Demo.swift 里，import 了 AppKit）。`VaultSync` 只用到 `AppEnv.vaultURL` 这一格。
- `--vault-selftest` 只在 `--demo` 下认，演示库在临时目录，跑一百遍碰不到真实笔记。它测的是**接上 Store 之后真的会动盘**：建库计数、外部改→采纳、App 改→防抖存盘顺带写 .md、双向冲突、外部删→补回、App 删→回收站、静默轮不留报告、FSEvents 自己收改动并写横幅。

最近一次全绿：**61 / 86 / 19**，`./build-app.sh` 无 error 无 warning。已 `ditto` 装到 `/Applications/桌面便签.app`。

## 6. 还欠什么

按重要性：

1. **真机上第一次建库**。让用户自己在「库」页点「建库」，然后核对 `<vault>/.desknote/state.json` 的份数 = 便签数 + 板数、`data.json` 还在、库里文件能双击进 Typora。测之前先 `cp data.json data.json.pre-vault`。
2. **README 已补**（功能条、库页四张图、数据与隐私里讲清 `vault/` 与 `.desknote/`、目录结构里补四个文件）。要再动就是措辞。真机上第一次建库之后可以补一张「冲突那份」的实拍图。
3. **库页还可以说的更清楚的地方**（都不影响正确性）：状态列双轨只覆盖「磁盘/DeskNote 谁动了」，冲突副本目前只在横幅里报数，表格里没单独一行；`.desknote/trash` 没有 UI 入口，只能访达进去。
4. **`[[双链]]` 只读**：反向链接已经在抽屉里列出来了，写路径（点链接建文件）没做——这是当初讲定的边界，别当 bug 报。
5. **两处配色欠账**（DESIGN.md 里明确记为「未 canonicalize 的缺陷」）：`DeadlineStatus` 还在直接刷 `.orange`/`.red`；库页「还没建库」那块仍用 `.tertiary` 打 10–11pt 小字，对比度不够。
6. **本轮所有改动都没提交**：`git status --short` 实测 10 改 + 13 新（新里面含 4 张库页截图）。提交前注意 `.impeccable/` 这个目录：`review/` 里是设计定稿图和 provenance，值得进仓库；`questions/seeds/` 里是本轮掷签的原始 key，设计约定它不进仓库。公开仓库是 **DeskNoteMac**（MIT），同名 `DeskNote` 是私有的 Windows/.NET 项目，别推错。提交需要用户点头。

## 6.1 演示实例的隔离（这一轮踩到的）

`--demo` 把 `data.json`、偏好和库都挪进临时目录，但**上一次 `--vault-selftest` 留在里面的 `state.json` 会活下来**：下一次 `Store.shared` 第一次存盘就会顺手跑一轮真同步，出图时多一条「已写入 8 份 · 7 份进了 .desknote/trash」的横幅——图就脏了。现在 `applicationDidFinishLaunching` 的 demo 分支开头会把演示库删掉，两个入口（出图 / 自检）都从干净目录起步。
改完这一段重新出过图：`library.png` 的横幅已经回到设计稿那样（只有过滤行和表格），四张库页图也换成了新的一份。核对过真实 `data.json` 的 md5 在出图前后没变。

## 7. 下一轮开工前必须遵守的（用户的规矩，别试）

- WebDAV 应用密码只在钥匙串（service `local.desknote.app` / account `webdav`）；不进 UserDefaults、不打印、不进 argv。**绝不代点钥匙串弹窗。**
- 真实 `data.json` 是工作笔记：不盲写、不盲恢复，测试期间不点「恢复」。有改动才备份。
- **后台验证**：只读观察（`CGWindowList(.optionAll)`、`screencapture -o -l<winid>`、md5、AX frame）。不合成点击、不 `keystroke`、不 `activate`、不动窗口、不动鼠标。截图只截目标窗口，绝不截全屏。
- 绝不用真注入热键来测热键（别的 app 会一起响）。用本地 IPC 触发。
- 攒够改动再一次构建一次重启，别让人重复授权同一个弹窗。构建后 `ditto build/桌面便签.app /Applications/桌面便签.app`，按路径启动，不用 `open -b`。
- 交接这一刻：`/Applications` 里已经是最新一份（二进制和 `build/` 里 cmp 相同），但**屏幕上跑的还是 10-30 20:13 从 `build/` 起的那个旧进程（pid 67624）**，它没有「库」这一页。要看得见，得用户自己退出重开——不代重启、不代点。
- 出图用打包后的二进制（裸 debug 二进制在 settings 那张会崩，`UNUserNotificationCenter` 要 bundle id）。
- 视觉稿在 `.impeccable/review/`（library / library-light / library-wide / library-error + provenance.md）；设计系统在 `DESIGN.md` + `.impeccable/design.json`；本轮的悬停高亮和焦点环是**代码证据，不是截图证据**——离屏 `cacheDisplay` 没有指针也没有 key window，真指针确认欠着，下次界面上屏时补。
