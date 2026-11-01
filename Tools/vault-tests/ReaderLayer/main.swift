import Foundation

var failures = 0
var passes = 0
func check(_ condition: Bool, _ description: String) {
    if condition { passes += 1 } else { failures += 1; print("✗ \(description)") }
}
func eq<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
    if actual == expected { passes += 1 }
    else {
        failures += 1
        print("✗ \(description)\n    实得 \(actual)\n    期望 \(expected)")
    }
}
func timed(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start) * 1000
}

// ReaderItem 不带 Equatable（它的内容是个枚举，比字符串数组更麻烦），
// 所以「有没有解析出来」这件事用这两个 helper 说，不靠 ==。
func got(_ items: [ReaderItem]?, _ description: String) {
    check(items != nil && !items!.isEmpty, description)
}
func stopped(_ items: [ReaderItem]?, _ description: String) {
    check(items == nil, description)
}

// 0 这一层为什么存在：解析搬进 ReaderParse 之后，「画」和「认字节」分在两个文件里，
// 而会写坏的是认字节这一半。SwiftUI 那份链不进这层，所以纯函数和缓存得能单独跑。
let prose = "# 标题\n\n正文一段\n"
let tabled = "# 标题\n\n| 甲 | 乙 |\n|:---:|---:|\n| 1 | 2 |\n\n末尾一行\n"

// 1 纯函数的口径在搬文件之后没变（视图那侧的断言在 Demo 里，这几条是这层的地板）
eq(ReaderParse.parse(prose)?.count, 1, "整篇散文就是一段")
let tableItems = ReaderParse.parse(tabled) ?? []
eq(tableItems.count, 3, "前散文 + 一张表 + 后散文")
if case .table(let rows, let aligns) = tableItems[1].content {
    eq(rows.count, 2, "表头加一行数据")
    eq(aligns, [CellAlignment.center, CellAlignment.trailing], "分隔行里的冒号就是对齐")
} else { check(false, "第二格该是表格") }
check(ReaderParse.parse("```swift\n![不是图](a.png)\n```")?.count == 1, "代码栅栏整块留着，不认里面的图")
if case .markdown(let converted) = (ReaderParse.parse("看 [[目标 甲|别名]] 那篇")?.first?.content ?? .markdown("")) {
    check(converted.contains("desknote://open?target="), "wiki 链接换成可点的 desknote 链接")
} else { check(false, "wiki 链接解析出散文段") }
if case .image(_, let destination, _, let cacheKey) = (ReaderParse.parse("![内嵌](data:image/png;base64,AAAA)")?.first?.content ?? .markdown("")) {
    eq(destination, "data:image/png;base64,AAAA", "data URI 当图片")
    check(cacheKey?.count == 64, "摘要在解析这一趟算好，滚动时不再重刷 base64")
} else { check(false, "内嵌图解析成 image 那一格") }

// 2 取消：查得够勤，而且半截结果什么都不留
stopped(ReaderParse.parse(prose) { true }, "一上来就要停：这一轮什么都不返回")
let manyLines = (0..<2_000).map { "第 \($0) 行正文" }.joined(separator: "\n")
var checks = 0
stopped(ReaderParse.parse(manyLines) { checks += 1; return checks >= 3 },
        "每 256 行查一次旗子：连打快键时前一轮真的能中途下来")
check(checks == 3, "它确实在第 512 行附近就下来了，没把 2000 行走完（查了 \(checks) 次）")

// 3 缓存按内容命中：重开、改名、移动都不必再解析
ReaderCache.resetCounters()
let first = ReaderCache.resolve(text: tabled, knownHash: nil)
eq(ReaderCache.misses, 1, "第一次没有缓存，只能老实解析")
eq(ReaderCache.hits, 0, "第一次谈不上命中")
got(first, "第一次拿到完整的解析结果")
let second = ReaderCache.resolve(text: tabled, knownHash: nil)
eq(ReaderCache.hits, 1, "同样一串字再来一次，命中缓存，不再解析")
eq(ReaderCache.misses, 1, "命中那一趟一个字节都没解析")
eq(second?.count, first?.count, "命中的那一版和解析出来的同构")
if case .table = second?[1].content ?? .markdown("") { passes += 1 } else { check(false, "命中回来的还是那张表") }

// 4 字节变了就是另一串字：缓存不认「差不多」
ReaderCache.resetCounters()
_ = ReaderCache.resolve(text: tabled + "多出来的一个字\n", knownHash: nil)
eq(ReaderCache.misses, 1, "改一个字符 → 新键 → 重解析")
eq(ReaderCache.hits, 0, "旧条目不会因为「像」就被拿出来用")

// 5 调用方带来的指纹直接当键用（LibraryDocument 读盘那一刻算的那一次）
ReaderCache.resetCounters()
let digest = ReaderParse.digest(manyLines)
got(ReaderCache.resolve(text: manyLines, knownHash: digest), "第一次仍然要解析")
eq(ReaderCache.misses, 1, "这一串字第一次见")
got(ReaderCache.resolve(text: manyLines, knownHash: digest), "第二次照样有结果")
eq(ReaderCache.hits, 1, "带着指纹来就不必再哈希整串")

// 6 半截结果不入库：被取消的那一轮没留下任何东西
ReaderCache.resetCounters()
let half = "# 半途\n\n" + (0..<3_000).map { "行 \($0)" }.joined(separator: "\n")
let halfHash = ReaderParse.digest(half)
stopped(ReaderCache.resolve(text: half, knownHash: halfHash, shouldStop: { true }), "取消的那轮不返回结果")
eq(ReaderCache.misses, 0, "没解析完的不算一次落空入账")
got(ReaderCache.resolve(text: half, knownHash: halfHash), "同一串字随后正常解析")
eq(ReaderCache.misses, 1, "正常那一轮老老实实解析了一次")
ReaderCache.resetCounters()
got(ReaderCache.resolve(text: half, knownHash: halfHash), "再问一次仍有结果")
eq(ReaderCache.hits, 1, "缓存里躺着的是完整的那一版，不是取消时的半截")

// 7 成本闸门：装不下的大条目不入库（带 Base64 内嵌图的那类就是这一种）
let giant = "# 大文档\n\n" + String(repeating: "这一行中文大概三十六个字左右，用来把整篇撑过缓存限额。\n", count: 120_000)
check(giant.utf8.count > ReaderCache.maximumEntryBytes,
      "样本真的超过了单条限额（\(giant.utf8.count / 1024 / 1024) MB）")
let giantHash = "giant-\(UUID().uuidString)"
ReaderCache.resetCounters()
let g1 = ReaderCache.resolve(text: giant, knownHash: giantHash)
let g2 = ReaderCache.resolve(text: giant, knownHash: giantHash)
eq(g1?.count, g2?.count, "同一个键两次都解析出同样的结构")
eq(ReaderCache.hits, 0, "超过限额的那类不进缓存：一条就能顶满 24 MB，把别的都挤出去")
eq(ReaderCache.misses, 2, "两次都是老实解析——这就是缓存出现之前的行为，不亏")
let giantMs = timed { _ = ReaderCache.resolve(text: giant, knownHash: giantHash) }
print("大文档 \(giant.utf8.count / 1024 / 1024) MB 整篇解析一轮：\(String(format: "%.0f", giantMs)) ms（不进缓存，每开一次付一次）")

// 8 命中省下多少：一篇 1 MB 出头的文档，冷解析 vs 命中（念给改代码的人听，不设阈值）
let warm = "# 基准\n\n" + String(repeating: "一段中文正文，读的时候要看它。\n", count: 40_000)
let warmHash = "warm-\(UUID().uuidString)"
got(ReaderCache.resolve(text: warm, knownHash: warmHash), "先把这一篇放进缓存")
let coldMs = timed { _ = ReaderCache.resolve(text: warm + "\n", knownHash: "cold-\(UUID().uuidString)") }
let hitMs = timed { _ = ReaderCache.resolve(text: warm, knownHash: warmHash) }
got(ReaderCache.resolve(text: warm, knownHash: warmHash), "命中路径返回的还是那一版")
check(coldMs > hitMs, "重开同一篇要比第一次快")
print("\(warm.utf8.count / 1024) KB：冷解析 \(String(format: "%.1f", coldMs)) ms → 缓存命中 \(String(format: "%.1f", hitMs)) ms（重开/改名省下的就是这些）")

// 9 散文在行边界分块：一整篇变成一个 chunk，NoteBodyView 每刷一帧都要在主线程把它重切成块，
//   那才是「滚动也卡」的正主。
func proseChunks(_ items: [ReaderItem]) -> [String] {
    items.compactMap { if case .markdown(let source) = $0.content { return source } else { return nil } }
}
let longDoc = (0..<20_000).map { "第 \($0) 行正文，这一行不短，用来把整篇压过分块的门槛。" }.joined(separator: "\n")
let chunks = proseChunks(ReaderParse.parse(longDoc) ?? [])
check(chunks.count > 1, "两万行分成 \(chunks.count) 块，不再是一整块")
eq(chunks.joined(separator: "\n"), longDoc, "分块不吞字节、不重叠，拼回去还是原文")
let heaviest = chunks.map { $0.utf8.count }.max() ?? 0
check(heaviest <= ReaderParse.markdownChunkBytes + longDoc.utf8.count / 20_000 + 8,
      "每一块都不超过限额加一行（最重的一块 \(heaviest / 1024) KB）")
let splitInText = proseChunks(ReaderParse.parse("![图](附件/a.png)\n" + longDoc) ?? [])
check(splitInText.count == chunks.count, "前面多一张图，后面那些行还是同样的分法：图不跟着散文一起切")

print("\n通过 \(passes) 条，失败 \(failures) 条")
exit(failures == 0 ? 0 : 1)
