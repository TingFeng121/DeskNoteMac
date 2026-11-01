# Obsidian 架构与能力：从安装包里取出的事实

更新日期：2026-11-01。目标是回答用户那句「还是好卡」：不要凭印象猜 Obsidian 怎么做，先把它的真实做法取出来，再决定 DeskNote 该怎么重排。

## 0. 这份文档的证据是怎么来的

工具是 REA 6.8.0（`rea-agents`，MCP + CLI）。这台机器上没有 npm，`node` 只有 Qoder 的 shim（v24.18.0，低于 REA 要求的 24.22.1），所以 Node 24.22.2 和 REA 都装在 `/tmp/rea/` 下面，没有动系统 PATH、没有装运行时、没有注册全局配置。

```
/tmp/rea/node-v24.22.2-darwin-arm64/bin/node \
  /tmp/rea/tool/node_modules/rea-agents/scripts/rea.mjs \
  analyze-javascript-application "/Applications/Obsidian.app/Contents/Resources/obsidian.asar" \
  --source-path worker.js --source-path main.js \
  --detail summary --evidence_output /tmp/rea/evidence/obs-index --max-heap-mb 2048 \
  --integrity-policy record-and-continue
```

- 被分析对象：`/Applications/Obsidian.app/Contents/Resources/obsidian.asar`，sha256 `a52a7daf1e2460bae03de80f2816604bd16a56cd374fbe5ce8d1a9ef5604059d`，对应本机安装的 Obsidian（bundle 内文件时间戳 2025-08-12）。
- Evidence bundle：`/tmp/rea/evidence/obs-index`（59 MB），evidence id `ev_0d07d41f…154b8`，provider `rea-javascript-application`，`authority: shipped-artifact`，`confidence: derived`。
- 第一次跑整个 asar 失败了（exit 1，无错误文本）：`lib/` 里 14 MB 的 codemirror/mathjax/pdfjs 把语义节点预算吃满了（`max_semantic_nodes_per_file = 20000` 已触顶）。所以改成只选 Obsidian 自己的模块。**这一条要记住：REA 的产物只在被选中的文件里成立。**
- `recover-javascript-sources`（反混淆成可读模块）在这台机器上用不了：它的 provider 是 Wakaru，只发 Linux x64 二进制。因此下面引用的都是压缩后的原文，我按字符串常量和属性名读——**属性名和字符串在 Obsidian 的压缩配置里是保留的**，类名和方法名不保留。文档里每个结论后面给的 `app.js@偏移` 就是这个意思：一个 3.8 MB 的单行文件，行号没有意义，字节偏移才是定位方式。

REA 自己声明的限制我原样搬过来，不要当成我加的客套：静态解析「JavaScript and HTML were parsed as inert text; bundle bootstrap code was never executed」，「Static imports, entrypoints, workers, endpoints, and storage relationships do not prove runtime execution」。也就是：**我看到的是代码写了什么，不是它跑出来的行为。**凡是行为结论我都另找了字符串或调用点做交叉印证。

包里的实际构成（`extractAll` 出来的，`/tmp/rea/obsidian-src/`）：

| 文件 | 大小 | 是什么 |
|---|---|---|
| `app.js` | 3.88 MB | 渲染进程，整个 app 的大脑 |
| `starter.js` | 441 KB | Electron 启动/窗口层（含 Capacitor 支付/评分） |
| `worker.js` | 239 KB | **Metadata Cache Worker**：markdown + YAML 解析 |
| `main.js` | 200 KB | Electron 主进程（很小，基本是宿主） |
| `help.js` | 377 KB | 内置帮助文档 |
| `i18n.js` + `i18n/` | 133 KB + 4.6 MB | 46 个语言的译文，**没有键名**，靠 `mapping.txt` 按行对齐 |
| `app.css` | 637 KB | 全部样式，主题变量在这里 |
| `sim.js` | 17 KB | **Graph Worker**：d3-force 布局 |
| `lib/` | 14 MB | codemirror / mathjax / pdfjs / reveal |

## 1. 进程模型：谁拿文件，谁做解析

`app.js@1747071` 附近：

```js
i.worker = new Worker("worker.js", {name: "Metadata Cache Worker"})
```
```js
new Worker("/sim.js", {name: "Graph Worker"})
```

所以 Obsidian 是四个执行体，职责一刀切干净：

- **主进程**（`main.js`）几乎不管业务。`fs.readFile` 只出现 1 次、`fs.watch` 0 次——它不管库。
- **渲染进程**（`app.js`）是应用主体，**所有文件 I/O 都在这里**：`fs.stat` 61 处、`rename` 19、`mkdir` 18、`readdir` 14、`writeFile` 8、`readFile` 7、`fs.watch` 3。Obsidian 的 BrowserWindow 不是沙箱的，渲染进程直接 `require("fs")`。
- **Metadata Cache Worker**（`worker.js`）做解析。它的字符串常量是 YAML 词法（`block-map`、`MISSING_CHAR`）加 markdown AST（`heading`、`listItem`、`blockquote`、`footnoteDefinition`、`callout-title`、`blockid`）加 `link`/`embed`/`tag`。** frontmatter、标题、链接、标签、嵌入的抽取全在主线程之外。**
- **Graph Worker**（`sim.js`）算图布局。

对照 DeskNote：一个进程、一条主线程，`VaultSync.sync` 里 `readFrontmatter` 和 `readProject` 都在主线程上跑。**这是「卡」的结构性原因，不是某个函数写得慢。**

## 2. 文件层：路径索引只存 stat，不存内容

`app.js@548181` 是这套东西的核心数据结构，压缩前大概长这样（我按原样还原，只加了名字）：

```js
function statRecord(stat) {
  return { ctime: Math.round(stat.birthtimeMs),
           mtime: Math.round(stat.mtimeMs),
           size:  stat.size };
}
var isDarwin = "darwin" === platform, isWin32 = "win32" === platform;
var canWatchRecursively = isDarwin || isWin32;

var FsCache = function (fs, path, url, trash, btime, resourcePrefix, basePath) {
  this.thingsHappening = debounce(this.kill.bind(this), 6e4, true);
  this.files = {};                     // path -> {type, realpath, ctime, mtime, size}
  this.promise = Promise.resolve();    // 串行队列
  this.watchers = {};
  this.insensitive = isDarwin || isWin32;
  try { this.testInsensitive(); } catch (e) { console.error(e); }
};
```

三个值得抄的细节：

**（a）记录里没有正文，也没有内容哈希。** 只有 `ctime/mtime/size`，一个文件十几字节。整库的路径索引装在内存里，不需要失效策略，因为它压根不缓存贵东西。

**（b）大小写敏感情况是启动时探出来的**，不是靠 `process.platform` 猜：

```js
FsCache.prototype.testInsensitive = function () {
  const up   = path.join(basePath, ".OBSIDIANTEST");
  const down = path.join(basePath, ".obsidiantest");
  if (fs.existsSync(up)) fs.unlinkSync(up);
  fs.writeFileSync(up, "", "utf8");
  this.insensitive = fs.existsSync(down);
  fs.unlinkSync(up);
};
```

同一个库放在大小写敏感卷上（外置 SSD、APFS 区分大小写的宗卷）行为会不一样，写死平台是错的。

**（c）一个 60 秒的失速断路器。** `queue()` 是串行执行器，每个任务和一个 reject 竞速：

```js
FsCache.prototype.kill  = function () {
  if (this.killLastAction) { this.killLastAction(new Error("File system operation timed out.")); this.killLastAction = null; }
};
FsCache.prototype.queue = function (task) {
  const wrapped = () => {
    const blocker = new Promise((_, rej) => { this.killLastAction = rej; });
    this.thingsHappening();                 // 6e4 ms，trailing/reset 型 debounce
    return Promise.race([blocker, task()]);
  };
  return (this.promise = this.promise.then(wrapped, wrapped));
};
```

含义：**文件系统在 60 秒内没有一刻安静下来，就当它坏了**，当前操作以超时失败，而不是无限等。慢盘、NFS、被杀毒软件挂住都走这条路。任务本身仍是串行的，`this.promise.then(f, f)` 保证一个失败不会把整条队断掉。

## 3. 变更检测：事件只做「这个路径可能变了」，判定靠 stat

`app.js@549399` 起，从事件到通知的完整链路：

```js
onFileChange(changed) {                        // fs.watch 的 change 回调
  if (!changed) return;
  changed = normalizeSlashes(changed);
  setTimeout(() => {                           // 同帧事件先合掉
    const key = normalizeName(changed);        // NBSP→空格 + NFC
    this.queue(() => this.reconcileFile(changed, key, false));
  }, 0);
}

reconcileFile(realPath, path, isNew) {
  this.trigger("raw", path);                   // 原始事件，给 UI 用
  if (isUnderDotDir(path)) return this.reconcileDeletion(realPath, path, isNew);
  const parent = dirname(path);
  if (parent && parent !== "/" && !this.files[path]) this.reconcileFile(realParent, parent, isNew);
  if (this.insensitive && realPath !== "/") {   // 用 readdir 核对真实大小写
    const entries = await fs.readdir(dirname(fullReal));
    if (!entries.map(normalizeName·NFC).includes(basename(path))) return this.reconcileDeletion(...);
  }
  try { await this.reconcileFileInternal(realPath, path); }
  catch (e) { if (e.code === "ENOENT") return this.reconcileDeletion(...); console.error(e); }
}

reconcileFileInternal(realPath, path) {
  const stat = await fs.lstat(fullReal);                    // 一次 lstat，没有读正文
  if (stat.isFile())        return this.reconcileFileCreation(realPath, path, stat);
  if (stat.isDirectory())   return this.reconcileFolderCreation(realPath, path);
  if (stat.isSymbolicLink())return this.reconcileSymbolicLinkCreation(realPath, path);
}

reconcileFileCreation(realPath, path, stat) {
  const fresh = statRecord(stat);
  const old = this.files[path];
  if (old) {
    old.realpath = realPath;
    if (old.type === "file") {
      if (old.mtime === round(stat.mtimeMs) && old.size === stat.size) return;   // 没变 → 不发事件
      old.mtime = round(stat.mtimeMs); old.size = stat.size;
      this.trigger("raw", path, path, fresh);
      this.trigger("modified", path, path, fresh);
      return;
    }
    this.removeFile(path);                                   // 文件↔目录换性
  }
  this.files[path] = … ; this.trigger("file-created", path, path, fresh);
}
```

`isUnderDotDir` 是 `app.js` 里的 `Il`，它**逐层往上走**，任何一级祖先以 `.` 开头就判为不可见：

```js
function isUnderDotDir(path) { while (path) { if (basename(path).startsWith(".")) return true; path = dirname(path); } return false; }
```

这条对 DeskNote 有直接意义。我现在写的 `VaultSync.isBookkeeping(_ path:root:)` 只精确匹配 `.desknote` 和 `.obsidian` 两个名字（[Sources/DeskNote/VaultSync.swift:57](file:///Users/tingfeng/Documents/AI%20PRJ/%E8%BD%AF%E4%BB%B6/DeskNote/Sources/DeskNote/VaultSync.swift#L57)）——它和 `Vault.markdownFiles` 的 `.skipsHiddenFiles` 口径是一致的，所以够用；但它挡不住用户自己建了个 `.git/` 里有 5 万个 .md 的情况。Obsidian 的做法是让**点开头目录整棵子树**都不进索引，而且是在 reconcile 阶段判，不是在事件阶段猜。

值得记住的三件事：
1. 事件只当提示，**真相由一次 `lstat` 决定**，代价是 O(1) 且与文件大小无关。
2. 判「变没变」只看 `mtime + size`。**没有整文件哈希，没有全目录重扫。**
3. 没变就**一个事件都不发**——下游完全不被吵到。

## 4. 解析层：两级缓存，串行队列，跨重启

`app.js@1746873` 附近的 MetadataCache 构造：

```js
this.worker      = null;
this.inProgressTaskCount = 0;
this.db          = null;          // IndexedDB，object store 名："metadata" 和 "file"
this.fileCache   = {};            // path -> {mtime, size, hash}
this.metadataCache = {};          // hash -> 解析结果
this.workQueue   = new SerialQueue();   // promise.then(task, task)
this.didFinish   = debounce(() => this.trigger("finished"), 10, true);
this.resolvedLinks = {}; this.unresolvedLinks = {};
this.userIgnoreFilters = null; this.userIgnoreFilterCache = {};
this.linkResolverQueue = new GeneratorQueue({onStop: () => this.trigger("resolved")});
this.worker = new Worker("worker.js", {name: "Metadata Cache Worker"});
```

命中判定（这是**整个性能设计的收口**）：

```js
let rec = this.fileCache[path];
let skip = false;
if (rec) {
  const untouched = rec.mtime === stat.mtime && rec.size === stat.size;   // 第 1 级：没动过
  const parsed    = rec.hash && this.metadataCache.hasOwnProperty(rec.hash); // 第 2 级：内容已经解析过
  skip = untouched && parsed;
} else { rec = {mtime: 0, size: 0, hash: ""}; this.saveFileCache(path, rec); }

if (!skip) {
  this.inProgressTaskCount++;
  this.workQueue.queue(() => { /* 读正文 → 算 hash → 交给 worker */ });
}
```

两级门都过才不重解析。第二级以**内容哈希**为键，带来两个白送的好处：改标题/移动文件（内容没变）不重解析；两份内容相同的文件只解析一次。

worker 侧的规矩写死在字符串里：

```js
if (this.workerResolve) return console.error("Messages must be sequential!");
return new Promise(res => { this.workerResolve = res; this.worker.postMessage({metadataCache: cache}, [cache]); });
```

一次只允许一条消息在飞——解析并发被**强制为 1**。UI 因此永远不会被解析洪峰挤掉。

队列本身是两个小东西（`app.js@1146096`、`1147810`）：

```js
// Pw：数组当优先队列，出队到一半就压缩
dequeue() { … if (2 * (t += 1) >= queue.length) { this.queue = queue.slice(t); t = 0; } … }
// Rw：生成器驱动的协作式队列，空了就 stop() 并 await 一个 deferred，来活了 setTimeout(0) 唤醒
generator*() { while (true) { if (cancelled) return;
  if (items.length === 0) { runnable.stop(); yield await this.promise; }
  else { runnable.start(); yield await items.dequeue(); } } }
```

`linkResolver` 就是这个生成器的消费者：每处理一项 `await` 一次，**把主线程让出去**。反向链接、别名解析这种长任务用它跑，所以一万条链接也不会冻结界面。

IndexedDB 那两个 store（`db.clear("metadata")` / `db.clear("file")`）说明**解析结果跨重启保留**：开库不是重扫，是把上次的答案读回来，再按 §3 的 stat 增量补差。

还有个很人文的细节（`app.js@1746949`）：

```js
showIndexingNotice() {
  … var s = window.setTimeout(() => { /* 1 秒后才把进度条挂出来 */ }, 1e3);
}
```

索引进度提示**延迟 1 秒才出现**，快活儿根本不会露脸。这比「一有活就转圈」好太多，DeskNote 该照做。

## 5. 搜索：不建索引库，扫内存里的缓存

`worker.js` 里 `indexOf` 出现 86 次，没有任何第三方索引库（没有 MiniSearch/FlexSearch/lunr）。搜索是**在已解析的内存缓存上线性扫**，配一组运算符。i18n 里 `plugins.search.*` 的运算符清单（69 条，取关键）：

`匹配文本: / 匹配正则表达式: / 精确匹配文本: / 大于：/ 小于：/ 值为真 / 值为假 / 值为空 / 包含笔记属性：/ 匹配所有: / 匹配任何: / 不包括: / 区分大小写 / 忽略大小写 / 匹配文件路径: / 匹配文件名: / 匹配文件内容: / 匹配任务列表：/ 匹配待办任务：/ 匹配已完成任务：/ 匹配行: / 匹配块：/ 匹配章节: / 匹配标签:`

结论：**个人规模的 markdown 库不需要 FTS/SQLite**。前提是 §4 的缓存必须先在，扫的是解析结果而不是磁盘。这条直接省掉 DeskNote 一整个「建索引」的负担。

## 6. 配置与状态的落盘

`app.js` 里 `.obsidian` 出现 32 次，配置文件名都是明文的：`app.json`、`workspace.json`、`core-plugins.json`、`community-plugins.json`；`localStorage` 63 处（窗口尺寸、`enable-plugin-<appId>` 这类），`indexedDB` 3 处（就是 §4 的缓存）。

对我修的那个自循环，Obsidian 给的答案是结构性的：**它往 `.obsidian/` 写的东西，它自己的路径索引根本不登记**（`isUnderDotDir` 在 reconcile 入口就 return），所以写记账文件不会产生事件、不会产生工作。我做的事等价——`isBookkeeping` + 只在 state 真变了才落盘——但 Obsidian 是**一条通用规则**，我目前是**一份名字清单**。

## 7. 能力清单：Obsidian 有、而且和插件无关的

来源是 i18n 的命名空间统计（`mapping.txt` 与 `zh.txt` 按行配对，2595 条）。第一段是分布，第二段是判定「去掉插件还剩什么」的依据：

```
plugins 1305   setting 511   interface 352   commands 99   dialogue 70
menu-items 53  editor 44     pdf 39         properties 32  nouns 28
table 22       main 21       callout 12      formulas 8
```

`plugins.*` 内部按功能计数（这就是 Obsidian 的功能目录）：

```
sync 225  publish 185  bases 156  canvas 130  search 69  web-viewer 68
file-explorer 52  graph-view 46  bookmarks 37  markdown-format-importer 30
custom-css 30  note-composer 29  daily-notes 26  properties 23  templates 22
quick-switcher 21  file-recovery 18  backlinks 17  workspaces 15
unique-note-creator 15  tag-pane 12  outgoing-links 11  page-preview 10
command-palette 10  outline 8  audio-recorder 8  open-with-default-app 6
footnotes-pane 5  editor-status 5  random-note 4  slides 3  word-count 2
translucency 2  slash-command 2  mermaid 2
```

注意：这些在 Obsidian 里**全都实现为插件**（核心插件也是插件，只是随包发）。用户说的「不要插件功能」我理解成两层，写下来免得后面各干各的：

- **不要的**：第三方插件加载、插件市场、`community-plugins.json`、插件权限提示、插件设置页框架。这些是**机制**，删掉不影响任何一个具体功能。
- **要的**：上面这张表里的**能力**，用 DeskNote 自己的代码实现，不做成可插拔。

`commands.*`（99 条）是不依赖任何插件的命令面，完整取出来放在这里作为目标清单（节选，全量在 `/tmp/rea/obsidian-keys-zh.tsv`）：

保存当前文件 / 下载当前文件内的所有附件 / 打开光标处的链接 / 在新标签页中打开光标处链接 / 在新标签组中打开 / 在新窗口中打开 / 聚焦上下左右标签页组 / 解锁·锁定 / 左右分屏 / 上下分屏 / 堆叠标签页 / 切换限制行宽 / 切换行号 / 返回·前进 / 切换深浅色 / 更换主题 / 切换仓库 / 打开仓库 / 管理仓库 / 在当前笔记中查找 / 查找替换 / 增加笔记属性 / 属性排序 / 添加别名 / 清除笔记属性 / 打开设置 / 查看帮助 / 切换编辑·阅读 / 切换实时阅览·源码 / 删除当前文件 / 新标签页 / 新窗口 / **打开回收站** / 关闭全部·当前·其他标签页 / 折叠左右边栏 / 显示隐藏功能区 / 在上方·下方添加光标 / 将焦点切换至编辑区 / 折叠展开笔记属性 / 折叠当前行 / 折叠所有标题和列表 / 与上一行·下一行互换 / 移除小标题 / 设为小标题 N / 加粗 / 倾斜 / 高亮 / 注释 / 清除格式 / 插入链接 / 拼写检查 / 删除段落 / **切换待办事项状态** / 列表·待办互转 / 插入标注 / 插入代码块 / 插入数学块 / 插入分隔线 / 插入表格 / 插入脚注 / 编辑文件名 / 复制路径 / 复制绝对路径 / 复制 Obsidian URI / 导出 PDF / **将当前窗口置顶** / 放大缩小重置缩放 / 移入新窗口 / 重命名当前文件 / 重新打开标签页 / 上下文菜单 / 显示调试信息

## 8. DeskNote 现在的样子，和差在哪

> 这一节是**动手前的诊断**，写的是 2026-11-01 开工前的代码形状，留着是为了对照。改完之后的状态看 §9.1 / §9.2 / §9.3，实测数字在 [HANDOFF](HANDOFF.md) 的「第三轮」一节。下面那张表里这些行已经过期：「每轮工作量：整棵树的每个 .md」（现在是事件清单）、「变更判定：读整份文件算 SHA256」（现在是 stat 闸门）、「内容寻址：没有这一级」（现在有了，见 §9.2）、「搜索：尚无库内搜索」（近文搜 + 按需深搜都有，仍然不建索引库）、「冷启动：每次重新扫」（`state.json` 现在带基线，只有首轮和漏事件付全额）、「解析在哪：主线程」（阅读侧解析改在 `Task.detached`，> 2 MB 的文档装载也走后台，见 §9.2）。仍然成立的是最后那一列的后半 —— `VaultSync.sync` 本身还是跑在主线程上，边界 4 没做，但实测已经看不见它，理由在 §9.1 末尾。

现状（[Sources/DeskNote/VaultSync.swift:149](file:///Users/tingfeng/Documents/AI%20PRJ/%E8%BD%AF%E4%BB%B6/DeskNote/Sources/DeskNote/VaultSync.swift#L149)、[Sources/DeskNote/Store.swift:136](file:///Users/tingfeng/Documents/AI%20PRJ/%E8%BD%AF%E4%BB%B6/DeskNote/Sources/DeskNote/Store.swift#L136)）每一轮同步是：

```
FSEvents → 0.5 s debounce → MainActor → Store.pullFromVault → VaultSync.sync:
    Vault.markdownFiles(root)           // 递归枚举整棵树，每次都是全部
    for 每个 .md: readFrontmatter(url)  // 打开文件、读头 64 KB、normalize 整个字符串
    for 每个已知对象: diskHash(url)      // 读整份文件算 SHA256
    appHash(内存对象)                    // 序列化再算一次 SHA256
    三方比较 → 写出 → 条件落盘 state.json
```

对照 Obsidian：

| | Obsidian | DeskNote 现在 | 代价差 |
|---|---|---|---|
| 每轮工作量 | 只有事件报的那个路径 | 整棵树的每个 .md | O(变更) vs O(全库) |
| 变更判定 | 1 次 `lstat`，比 `mtime+size` | 读整份文件算 SHA256 | 常数级 vs 与文件大小成正比 |
| 内容寻址 | `hash → 解析结果`，改标题不重解析 | 没有这一级 | 重命名/移动 = 全量重算 |
| 解析在哪 | `worker.js`，主线程外 | 主线程 | 主线程被 I/O + 解析占满 |
| 并发 | 强制串行，worker 一次一条消息 | 一次 `sync()` 一把梭 | 没有让出点 |
| 隐藏目录 | `isUnderDotDir` 通用规则 | `isBookkeeping` 名单 | 名单外的点目录会咬自己 |
| 失速保护 | 60 s 断路器 + 报错 | 无 | 慢盘直接冻住 |
| 冷启动 | IndexedDB 里有上次的答案 | 每次重新扫 | 每次都付全额 |
| 搜索 | 扫内存缓存，无索引库 | 尚无库内搜索 | 不用建索引，前提是先有缓存 |
| 进度提示 | 1 s 后才出现 | 无（直接卡住） | 观感 |

**一句话诊断：DeskNote 把「文件系统发生了什么」和「我该重算哪些」这两件事合成了一个动作——重扫全库。Obsidian 把它们分成两级，中间用 stat 和 mtime+size 挡掉 99% 的工作。**

## 9. 目标架构（下一轮的施工图）

按 §1–§6 的形状重排，不引入插件系统。四条边界：

1. **路径索引**（新文件 `VaultIndex`）——`[path: Entry]`，`Entry = {kind, realpath, mtimeMs, size, ctimeMs, objectID}`。只 `lstat`，不读正文。事件到达只更新被点到的路径。祖先含 `.` 的一律不进索引。大小写敏感性启动时探测。
2. **变更判定**——`mtime + size` 不变 ⇒ 不发通知。`App ↔ 磁盘` 的三方比较保留（这是 DeskNote 独有的，Obsidian 没有 App 侧内存真源），但输入换成 `(mtime, size)` + **只在候选集内**才读全文算哈希。候选集来自第 1 层，通常是 0。
3. **解析在后台**——`LibraryReader` 已经是后台快照（[Sources/DeskNote/LibraryReader.swift](file:///Users/tingfeng/Documents/AI%20PRJ/%E8%BD%AF%E4%BB%B6/DeskNote/Sources/DeskNote/LibraryReader.swift)），补上它缺的两级缓存：`[path: (mtime, size, contentHash)]` + `[contentHash: 渲染结果]`，串行队列，一次一个。
4. **主线程只做界面**——`VaultSync.sync` 不再由 `Task { @MainActor in … }` 直接调用；索引更新跑在自己的 actor/串行队列上，只有最终 `Report` 回主线程合并。

`state.json` 的语义不变（本地账，不是同步对象），但降级为**冷启动加速器**：有它就不用把整棵树 `lstat` 一遍；它失效就退回全量扫。不再每轮写。

不做的：Canvas、Bases、Sync/Publish、Web Clipper、Graph view、社区插件、PDF 导出。
**MathJax/KaTeX 公式与 Mermaid 于 2026-11-01 已做**（离线 vendor，只在阅读模式，见 §9.3 与 [HANDOFF 的高级渲染一节](HANDOFF.md)），§7 能力清单里那两行不再是差距。用户脚本、Dataview、社区插件 API 仍然没有——能画 Mermaid 不等于能跑别人的插件。
DeskNote 独有、必须保住的：钉桌面便签、待办三层、触发角、全局热键、菜单栏、WebDAV 备份、冲突副本、`desknote.id` 身份。

### 9.1 边界 1 + 2 已落地（2026-11-01）

`VaultIndex` 落在 [Sources/DeskNote/VaultSync.swift:51](file:///Users/tingfeng/Documents/AI%20PRJ/%E8%BD%AF%E4%BB%B6/DeskNote/Sources/DeskNote/VaultSync.swift#L51)（和 `FileStamp` 同一个文件，保持只有 Foundation 这一条约束），`sync` 的入参从 `full: Bool` 换成 `diskPaths: [String]?`：

| `diskPaths` | 谁用 | 磁盘这一趟做多少 |
|---|---|---|
| `nil` | 冷启动、换库、`kFSEventStreamEventFlagMustScanSubDirs` | 整库重走 + 每个文件重读（连 state.json 那格 stat 也不信） |
| `[]` | 每次存盘（`Store.pushToVault`） | 一个目录也不走；只 stat 自己那几份对象 |
| 有值 | `VaultWatcher` 攒下的事件路径 | 只 stat 报上来的路径；目录事件重走那一层 |

时间戳按整毫秒比（`FileStamp.ms`），和 §2 里 Obsidian 的 `Math.round(e.mtimeMs)` 同一个取舍：`timeIntervalSinceReferenceDate` 在这个量级上，一次「贴回原时间再读出」的往返就会在第 7 位小数上对不上，用裸 Double 判相等等于把没动的文件读成动了的。

实测（`Tools/vault-tests/run.sh sync` 的第 20、21 节，213 份 .md + 一张 0.8 MB 内联图便签）：

| 一轮 | 整改前 | 整改后 |
|---|---|---|
| App 侧（每次存盘） | ≈ 整库重走 | **0.75 ms** |
| 整库重走 | 每次都付 | 96 ms，其中枚举 39 ms、逐份 stat 2.7 ms、App 侧哈希 0.5 ms |
| 全库重读算哈希 | — | 7.0 ms（`Vault.hash` 的十六进制编码换掉 `String(format: "%02x")` 之后；之前 13.3 ms） |

**这一条把边界 4 的必要性基本消掉了**：主线程上原来占着的是那 40–190 ms 的整库枚举，现在每 0.4 秒那一轮只剩零点几毫秒。剩下的整库重走只发生在冷启动和漏事件，不在交互路径上。所以下一步是**实测确认**（真库 relaunch 之后 `sample` 一轮），不是先把 `sync` 搬去后台线程——把三方比对搬走要处理 `data` 快照与合并，风险大于收益，除非实测显示 `[]` 那一轮仍然可见。

边界 3 也在同一天落地了，见下面的 §9.2；高级渲染（§7 表里的 callout / formulas / mermaid / markdown 格式）在 §9.3。

### 9.2 边界 3 已落地（2026-11-01）：按内容哈希的解析缓存 + 大文档后台装载

形状照 §4 来，但**两级降成一级**，这是和施工图的一处有意偏差：

| §4 / §9 原设计 | 实现 | 为什么 |
|---|---|---|
| `[path: (mtime, size, contentHash)]` + `[contentHash: 渲染结果]` | 只有 `[contentHash: [ReaderItem]]`（`ReaderCache`，`NSCache`，`countLimit 24`、24 MB） | L2 按内容命中，本来就把「重开 / 改名 / 移动」全包了；再加一本 `path → hash` 的账只多一个会过期的地方。stat 闸门在 `LibraryDocument` 那一层（`FileStamp`），没变的文件连读都不读，用不着第二本账。 |
| 解析结果里带图片字节 | 单条 **超过 6 MB 直接不进缓存** | 不然 L2 一个条目就等于那份大文档，缓存自己变成常驻内存的那只手。宁可重算，不常驻。 |
| 串行队列，一次一条消息 | `Task.detached` + 可取消，每 256 行查一次取消位；`.task(id:)` 的键换成内容哈希 | 切文档时旧任务自己退场，连打快键不再同时跑 N 份整篇 `components(separatedBy: .newlines)`。 |
| — | `LibraryDocument.open` 对 > 2 MB（`ReaderCache.synchronousLoadLimit`）走后台装载，装载期间 `edited()` / `save()` 一律拒绝 | 这条同时是**数据安全闸门**：磁盘基线没到手之前，不许键盘往盘上写。 |

实测（`Tools/vault-tests/run.sh reader` 的基准段）：1796 KB 的一份，冷解析 **157.5 ms → 命中 0.0 ms**；9 MB 整篇 734 ms 不缓存。`LibraryScan` 那一侧的常驻正文：213 份库 **358 KB**（磁盘 1295 KB），因为行里只留 `head`（前 32 KB）+ 一个 `truncated` 位。代价写实：近文搜只看前 32 KB，更深处由 `LibrarySearch` 那条显式动作按需分块流式读（20 份 / 7 MB 27.2 ms）。

§8 那张对照表里现在另有两行过期：「内容寻址：没有这一级」——有了，就是上面这个；「搜索：尚无库内搜索」——库内搜索有（近文 + 深搜两条），仍然**不建索引库**，和 Obsidian 一样扫内存里的行集，这是 §5 的原意。

### 9.3 §7 的能力表里，与渲染有关的那几行已补齐（2026-11-01）

`callout 12` / `formulas 8` / `mermaid 2` / `markdown-format-importer` 落在阅读模式：markdown-it 15.0.3 + markdown-it-footnote 4.0.0 + DOMPurify 3.4.17 + highlight.js 11.12.0 + KaTeX 0.19.1 + mermaid 12.2.0，全部离线 vendor 在 `MarkdownRenderer/`（40 个文件 / 6.2 MB，逐文件 SHA-256 在 `VERSIONS.json`），CSP `default-src 'none'; connect-src 'none'`，**不需要 `'unsafe-eval'`**。一个 `WKWebView` 实例按需创建、切文档复用，不为每个块建 WebView。编辑与分屏仍是原生 `NSTextView`。

这一条**不含**用户脚本、Dataview 和社区插件 API。渲染 Mermaid 不等于能执行别人写的 JS，两者不许混称。

§9 清单里有两条没另写，原因记在这儿：`isUnderDotDir` 那条祖先规则不用实现，`Vault.markdownFiles` 带 `.skipsHiddenFiles`，账压根看不见点目录里的东西；大小写敏感性探测也没有对象，DeskNote 不按小写路径去重，改名要真改到 inode 才认。


## 10. 还没证实的

- Obsidian 主进程到底怎么处理多窗口共享同一库（`starter.js` 没进这次的分析范围）。
- `userIgnoreFilters` 的存储位置与求值时机（看到了字段名，没跟到写入点）。
- 渲染进程读大文件（几十 MB 附件）时的分块策略；`readFile` 调用点没显示流式读。
- 以上都是「没看到」，不是「没有」。REA 的 26 条 unknown 里有 18754 条语义节点被预算截断，`lib/` 与 `starter.js` 完全在范围外。
