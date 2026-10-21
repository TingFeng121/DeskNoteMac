import AppKit
import SwiftUI

// MARK: - SwiftUI 入口

/// Typora 式便签编辑器：# 井号、- 短横、[ ] 方括号、** 星号打完就消失，正文立刻变成
/// 标题/项目符号/勾选框/粗体，但 textStorage 里存的始终是原始 Markdown。
///
/// 之所以选「只改属性把符号藏起来」而不是「显示文本与存储文本分开维护」：
/// 前者让输入法组字、撤销重做、粘贴、选中全部走 AppKit 原生路径，我们不需要维护两套下标映射，
/// 存盘也就是把 string 交出去；后者任何一个环节算错下标都会吃掉用户打的字。
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// 桌面浮窗和正文栏打开即打字；卡片墙里的就地编辑不抢焦点，点谁哪儿。
    var autoFocus = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        let tv = MarkdownTextView()
        tv.baseFontSize = CGFloat(fontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.inkColor = .labelColor
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        // 自动替换会把 -- 变成破折号、把引号换成弯引号，直接破坏 Markdown 语法
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NoteLayout.editorInset
        tv.delegate = context.coordinator
        tv.loadMarkdown(text, keepSelection: false)
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        tv.baseFontSize = CGFloat(fontSize)
        // 只有外部改了正文才回写（预览里点勾、恢复备份、换一张便签）。自己打字时两边恒等，
        // 一旦整段重设，插入点就会被弹到末尾——「按删除键光标跳到最后」正是这么来的。
        if tv.string != text { tv.loadMarkdown(text) }
        if autoFocus, !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var didFocus = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? MarkdownTextView else { return }
            text.wrappedValue = tv.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? MarkdownTextView)?.selectionChanged()
        }
    }
}

// MARK: - 编辑器

final class MarkdownTextView: NSTextView {
    var baseFontSize: CGFloat = 13 {
        didSet { guard baseFontSize != oldValue else { return }; restyle(force: true) }
    }

    /// 正文墨色。绝不能就地取 `textColor`：那只是 typingAttributes 的一个投影，
    /// 而 typingAttributes 会被我们涂成 clear 的语法符号污染，取回来就是全透明，整段文字直接消失。
    var inkColor: NSColor = .labelColor

    /// 被藏起来的语法符号，删除键要整段吞掉而不是让用户去数看不见的字符
    private var hiddenRuns: [NSRange] = []
    /// 需要在页边额外画东西的行（项目符号、勾选圈、序号、引用条、分隔线）
    private var marks: [(para: NSRange, kind: MarkdownSyntax.LineKind, depth: Int)] = []
    private var codeParas: [NSRange] = []
    private var typingByPara: [(NSRange, [NSAttributedString.Key: Any])] = []
    private var restyling = false

    private static let hiddenParaStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.1
        p.maximumLineHeight = 0.1
        return p
    }()

    /// 藏字符 = 字号压到 0.1 再涂透明。试过 .expansion = -1，实测推进宽度并不会塌缩。
    /// 这里绝不能带 paragraphStyle：段落样式取段首字符那份，行首标记正好是段首，
    /// 一塞进去整行（标题、列表、分隔线）都会被压成 0.1 高。
    private static let hiddenRunAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.1),
        .foregroundColor: NSColor.clear,
    ]

    /// 行内标记的字符集。一段行文里一个都没有就不用六个正则都跑一遍
    static let inlineTriggers = CharacterSet(charactersIn: "*_~`")

    /// 整行都要塌掉的（代码围栏那两行 ```）才允许带段落样式
    private static let hiddenLineAttrs: [NSAttributedString.Key: Any] = {
        var attrs = hiddenRunAttrs
        attrs[.paragraphStyle] = hiddenParaStyle
        return attrs
    }()

    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    /// 外部整体替换正文：绕开 didChangeText，免得把改动又回写一遍存储层
    func loadMarkdown(_ md: String, keepSelection: Bool = true) {
        let caret = min(selectedRange().location, (md as NSString).length)
        let base = NSFont.systemFont(ofSize: baseFontSize)
        textStorage?.setAttributedString(NSAttributedString(string: md, attributes: [
            .font: base,
            .foregroundColor: inkColor,
            .paragraphStyle: MarkdownStyle.para(.plain, size: baseFontSize),
        ]))
        // 刚把整段属性抹平，正文可能跟上一次排版时一模一样，这一下必须真排
        restyle(force: true)
        if keepSelection { setSelectedRange(NSRange(location: caret, length: 0)) }
    }

    // MARK: 排版

    /// 上一次排版对应的「正文 + 字号」。打一个字会同时走存储层通知和 didChangeText，
    /// 两遍整篇排版里后那遍内容根本没变，白排。
    private var styledText: String?
    private var styledSize: CGFloat = -1

    /// `force` 给「正文没变但属性被我们抹掉了」的场合用：外部整体塞文本时不重排就是一片裸文本。
    func restyle(force: Bool = false) {
        // 输入法正在组字时不能动属性，否则候选框会跳、上屏会错
        guard !restyling, let storage = textStorage, !hasMarkedText() else { return }
        let document = storage.string
        if !force, document == styledText, baseFontSize == styledSize { return }
        styledText = document
        styledSize = baseFontSize
        restyling = true
        defer { restyling = false }

        let ns = document as NSString
        let ink = inkColor
        let base = NSFont.systemFont(ofSize: baseFontSize)

        hiddenRuns = []
        marks = []
        codeParas = []
        typingByPara = []

        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: ink,
                               .paragraphStyle: MarkdownStyle.para(.plain, size: baseFontSize)],
                              range: NSRange(location: 0, length: ns.length))
        var inFence = false
        MarkdownSyntax.forEachParagraph(ns) { para, raw in
            let content = MarkdownSyntax.contentRange(ns, para)
            let line = ns.substring(with: content)
            let info = MarkdownSyntax.classify(line)

            if info.kind == .fence {
                // 围栏连换行一起缩掉，这一行塌成 0 高，看起来跟不存在一样
                storage.addAttributes(Self.hiddenLineAttrs, range: para)
                hiddenRuns.append(para)
                inFence.toggle()
                return
            }
            style(kind: inFence ? .code : info.kind, para: para, content: content,
                  line: line, ns: ns, info: info, storage: storage, ink: ink)
        }
        storage.endEditing()

        needsDisplay = true
        syncTypingAttributes()
    }

    private func style(kind: MarkdownSyntax.LineKind, para: NSRange, content: NSRange, line: String,
                       ns: NSString, info: MarkdownSyntax.LineInfo, storage: NSTextStorage, ink: NSColor) {
        var font = NSFont.systemFont(ofSize: baseFontSize)
        var color = ink
        switch kind {
        case .plain, .fence, .bullet, .todo, .numbered, .divider:
            break
        case let .heading(level):
            font = NSFont.systemFont(ofSize: MarkdownSyntax.headingSize(baseFontSize, level), weight: .bold)
        case .quote:
            color = .secondaryLabelColor
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case .code:
            font = NSFont.monospacedSystemFont(ofSize: max(9, baseFontSize - 1), weight: .regular)
            codeParas.append(para)
        }

        // 代码里的空白是代码本身的内容，不能当成层级吃掉
        let depth = kind == .code ? 0 : info.depth
        let paraStyle = MarkdownStyle.para(kind, size: baseFontSize, depth: depth)
        storage.addAttribute(.paragraphStyle, value: paraStyle, range: para)
        if content.length > 0 {
            storage.addAttribute(.font, value: font, range: content)
            storage.addAttribute(.foregroundColor, value: color, range: content)
        }

        // 六个正则逐段跑一遍并不便宜，而绝大多数行里一个星号下划线都没有
        if kind != .code, kind != .divider, content.length > 0,
           line.rangeOfCharacter(from: Self.inlineTriggers) != nil {
            for mark in MarkdownSyntax.inlineMarks(ns, in: content) {
                var f = font
                if mark.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if mark.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if mark.mono { f = NSFont.monospacedSystemFont(ofSize: f.pointSize, weight: .regular) }
                storage.addAttribute(.font, value: f, range: mark.inner)
                if mark.strike {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: mark.inner)
                }
                for d in mark.delims where d.length > 0 {
                    storage.addAttributes(Self.hiddenRunAttrs, range: d)
                    hiddenRuns.append(d)
                }
            }
        }

        // 行首缩进整块藏掉：往里排靠的是段落样式，空格再留在原地就成了两级变四级。
        // 一块一级，删除键也就是一次退一级（deleteBackward 按 hiddenRuns 整段吞）。
        if kind != .code {
            for chunk in info.indentChunks {
                guard chunk.location <= content.length else { break }
                let run = NSRange(location: content.location + chunk.location,
                                  length: min(chunk.length, content.length - chunk.location))
                guard run.length > 0 else { continue }
                storage.addAttributes(Self.hiddenRunAttrs, range: run)
                hiddenRuns.append(run)
            }
        }

        // 行首标记最后藏：前面所有属性都按整段铺过，这一步盖上去才不会又被放大。
        // 必须用 addAttributes——段落的排版样式取段首字符那一份，setAttributes 会把它抹掉，
        // 整行于是退化成 0.1pt 行高。
        let marker = NSRange(location: content.location + info.marker.location,
                             length: min(info.marker.length,
                                         max(0, content.length - info.marker.location)))
        if marker.length > 0 {
            storage.addAttributes(Self.hiddenRunAttrs, range: marker)
            hiddenRuns.append(marker)
        }
        if kind == .divider, content.length > 0 {
            storage.addAttributes(Self.hiddenRunAttrs, range: content)
            hiddenRuns.append(content)
        }

        switch kind {
        case .bullet, .todo, .numbered, .quote, .divider: marks.append((para, kind, depth))
        default: break
        }
        typingByPara.append((para, [.font: font, .foregroundColor: color, .paragraphStyle: paraStyle]))
    }

    /// 光标停在被隐藏的语法符号上时，存储里的字是 0.1pt 透明的，直接打字就等于没打。
    /// 所以打字用的属性按「这一段本来该长什么样」给，而不是照抄存储。
    func syncTypingAttributes() {
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let loc = min(max(0, selectedRange().location), max(0, ns.length - 1))
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        if let attrs = typingByPara.first(where: { $0.0 == para })?.1 {
            typingAttributes = attrs
        }
    }

    func selectionChanged() {
        syncTypingAttributes()
        // 光标掉进看不见的符号中间时挪到符号末尾，不然打进去的字会被当成语法符号吃掉
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        for run in hiddenRuns where run.location < sel.location && sel.location < NSMaxRange(run)
            && NSMaxRange(run) <= storage.length {
            setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
            return
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawCodeBlocks(dirtyRect)
        super.draw(dirtyRect)
        drawMarginMarks(dirtyRect)
    }

    private func fragments() -> (NSLayoutManager, NSTextContainer, NSString)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        return (lm, tc, storage.string as NSString)
    }

    private func drawCodeBlocks(_ dirtyRect: NSRect) {
        guard !codeParas.isEmpty, let (lm, tc, ns) = fragments(), ns.length > 0 else { return }
        let origin = textContainerOrigin
        let width = tc.size.width
        // quaternaryLabelColor 本身只有 ~0.1 不透明度，再乘一层就什么都看不见了
        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        var merged: [NSRange] = []
        for para in codeParas {
            if let last = merged.last, last.location + last.length == para.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: last.length + para.length)
            } else {
                merged.append(para)
            }
        }
        for range in merged {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let r = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
            guard r.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: NSRect(x: origin.x, y: r.minY - 4, width: max(1, width),
                                             height: r.height + 8),
                         xRadius: 5, yRadius: 5).fill()
        }
    }

    private func drawMarginMarks(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let (lm, tc, ns) = fragments(), ns.length > 0 else { return }
        let origin = textContainerOrigin
        for entry in marks {
            let glyphs = lm.glyphRange(forCharacterRange: entry.para, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var used = NSRange(location: 0, length: 0)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &used)
            guard fragment.height > 0 else { continue }
            let full = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            // 页边那条的宽度按第 0 级算，层级靠 x 往里推。用带层级的 firstLineHeadIndent 当宽度，
            // 越深的列表符号越往右飘，圆点和正文字就各排各的位了
            let slot = NSRect(x: origin.x + fragment.minX + 2 + CGFloat(entry.depth) * MarkdownStyle.indentStep,
                              y: origin.y + fragment.minY,
                              width: max(10, MarkdownStyle.baseIndent(entry.kind) - 5),
                              height: fragment.height)
            let box = NSRect(x: origin.x + full.minX, y: origin.y + full.minY,
                             width: full.width, height: full.height)
            guard slot.intersects(dirtyRect) || box.intersects(dirtyRect) else { continue }
            draw(entry.kind, at: slot, full: box)
        }
    }

    private func draw(_ kind: MarkdownSyntax.LineKind, at slot: NSRect, full: NSRect) {
        switch kind {
        case .bullet:
            label("•", in: slot, color: .secondaryLabelColor, alignment: .center)
        case let .numbered(digits):
            // 右对齐：1. 和 12. 的句点要对齐，正文才不会被推来推去
            label(digits + ".", in: slot, color: .secondaryLabelColor, alignment: .right)
        case let .todo(done):
            checkbox(in: slot, done: done)
        case .quote:
            let bar = NSRect(x: slot.minX + 1, y: full.minY + 2, width: 2, height: max(2, full.height - 4))
            NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        case .divider:
            NSColor.separatorColor.setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: full.minX + 2, y: full.midY))
            rule.line(to: NSPoint(x: full.maxX - 2, y: full.midY))
            rule.stroke()
        default:
            break
        }
    }

    private func label(_ text: String, in rect: NSRect, color: NSColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: baseFontSize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func checkbox(in rect: NSRect, done: Bool) {
        let d = max(10, baseFontSize)
        let box = NSRect(x: rect.midX - d / 2, y: rect.minY + (rect.height - d) / 2, width: d, height: d)
        let circle = NSBezierPath(ovalIn: box.insetBy(dx: 0.8, dy: 0.8))
        circle.lineWidth = 1.2
        if done {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let tick = NSBezierPath()
            tick.lineWidth = 1.4
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.move(to: NSPoint(x: box.minX + d * 0.28, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + d * 0.44, y: box.minY + d * 0.22))
            tick.line(to: NSPoint(x: box.minX + d * 0.74, y: box.maxY - d * 0.24))
            tick.stroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            circle.stroke()
        }
    }

    // MARK: 输入

    /// 回车续上同一级列表；空条目回车则收掉标记，回到普通段落。
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0, !hasMarkedText(), ns.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length - 1), length: 0))
        let content = MarkdownSyntax.contentRange(ns, para)
        let line = ns.substring(with: content)
        let lineNS = line as NSString
        let info = MarkdownSyntax.classify(line)
        let head = lineNS.substring(to: min(info.marker.location, lineNS.length))
        let marker = lineNS.substring(with: info.marker)
        let bodyStart = min(NSMaxRange(info.marker), lineNS.length)
        let body = lineNS.substring(from: bodyStart).trimmingCharacters(in: .whitespaces)

        let next: String
        switch info.kind {
        case .bullet: next = head + marker
        case .todo: next = head + "- [ ] "
        case let .numbered(digits): next = head + "\((Int(digits) ?? 0) + 1). "
        case .quote: next = head + "> "
        default:
            super.insertNewline(sender)
            return
        }
        guard !body.isEmpty else {
            // 空条目：这一行只剩标记，删掉标记就是退出列表
            let run = NSRange(location: content.location + info.marker.location, length: info.marker.length)
            if run.length > 0, shouldChangeText(in: run, replacementString: "") {
                replaceCharacters(in: run, with: "")
                didChangeText()
            }
            return
        }
        insertText("\n" + next, replacementRange: sel)
    }

    // MARK: 缩进

    /// Tab 往里一级、Shift-Tab 退一级。往正文里存的是空格而不是制表符：
    /// 段落样式的层级、回车续行的缩进、卡片预览的对齐三处都按「两格一级」算，
    /// 混进制表符的话这三处会各数出不同的宽度。
    override func insertTab(_ sender: Any?) { shiftIndent(levels: 1, sender: sender) }
    override func insertBacktab(_ sender: Any?) { shiftIndent(levels: -1, sender: sender) }

    private func shiftIndent(levels: Int, sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        // 空文档、组字中、代码围栏里（那里的空白是代码本身的内容）——都交给系统的 Tab
        if ns.length == 0 || hasMarkedText()
            || codeParas.contains(where: { NSLocationInRange(min(sel.location, ns.length - 1), $0) }) {
            if levels > 0 { super.insertTab(sender) } else { super.insertBacktab(sender) }
            return
        }
        let caret = min(sel.location, ns.length - 1)
        let para = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let tailAt = max(para.location, min(NSMaxRange(sel), ns.length - 1))
        let lastPara = ns.paragraphRange(for: NSRange(location: tailAt, length: 0))
        let multiLine = lastPara.location > para.location
        let cols = levels * MarkdownSyntax.indentCols

        // 光标孤零零停在一段普通正文中间：这儿没有列表标记也没有已有层级，
        // 把 Tab 当成空白插进去，别硬把整行往里推
        if !multiLine, cols > 0 {
            let info = MarkdownSyntax.classify(ns.substring(with: MarkdownSyntax.contentRange(ns, para)))
            if info.depth == 0, info.marker.length == 0 {
                insertText(String(repeating: " ", count: cols), replacementRange: sel)
                return
            }
        }
        var lines: [String] = []
        var loc = para.location
        while true {
            let row = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let line = ns.substring(with: MarkdownSyntax.contentRange(ns, row))
            if cols > 0 {
                lines.append(String(repeating: " ", count: cols) + line)
            } else {
                lines.append(String(line.dropFirst(Self.indentCharsRemoved(line, cols: -cols))))
            }
            if NSMaxRange(row) >= NSMaxRange(lastPara) { break }
            loc = max(NSMaxRange(row), loc + 1)
        }
        let body = lines.joined(separator: "\n")
        // 这段范围末尾本来就带换行的要还回去，不然两行会被并成一行
        let trailing = ns.character(at: NSMaxRange(lastPara) - 1) == 0x0A ? "\n" : ""
        let replacement = body + trailing
        let span = NSRange(location: para.location, length: NSMaxRange(lastPara) - para.location)
        // 改之前的行宽得先记下：`string as NSString` 拿到的就是存储层那个可变串，
        // 替换完再看同一个对象已经是新内容了，拿旧下标去取会越界
        let firstLine = ns.substring(with: MarkdownSyntax.contentRange(ns, para))
        let firstLen = (firstLine as NSString).length
        guard shouldChangeText(in: span, replacementString: replacement) else { return }
        replaceCharacters(in: span, with: replacement)
        didChangeText()

        // 多行选区保持整块选中，连按 Tab 才是一级一级往里走；单光标跟着行首挪的字数走
        if multiLine || sel.length > 0 {
            setSelectedRange(NSRange(location: para.location, length: (body as NSString).length))
        } else {
            let moved = (body as NSString).length - firstLen
            setSelectedRange(NSRange(location: min(max(sel.location + moved, para.location),
                                                   para.location + (body as NSString).length), length: 0))
        }
    }

    /// 退一级要从行首吃掉几个字符：制表符一个就顶两格，够数就停
    private static func indentCharsRemoved(_ line: String, cols: Int) -> Int {
        var seen = 0, chars = 0
        for ch in line {
            guard ch == " " || ch == "\t" else { break }
            let width = ch == "\t" ? MarkdownSyntax.indentCols : 1
            guard seen + width <= cols else { break }
            seen += width
            chars += 1
        }
        return chars
    }

    /// 删除键一次吞掉整段语法符号：符号是看不见的，一个一个删会让用户摸不着头脑。
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0,
           let run = hiddenRuns.first(where: { $0.length > 0 && NSMaxRange($0) == sel.location }) {
            let range = NSRange(location: run.location, length: sel.location - run.location)
            if range.length > 0, shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
                return
            }
        }
        super.deleteBackward(sender)
    }

    // 撤销/重做可能只回滚字符串不滚属性，存储层一动就重新排版一次
    private var observesStorage = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !observesStorage, let storage = textStorage else { return }
        observesStorage = true
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                               object: storage, queue: .main) { [weak self] _ in
            self?.restyle()
        }
    }
}

// MARK: - 语法识别

enum MarkdownSyntax {
    enum LineKind: Equatable {
        case plain, heading(Int), bullet, todo(Bool), numbered(String), quote, divider, fence, code
    }

    struct LineInfo {
        var kind: LineKind = .plain
        /// 行首要藏起来的语法符号，按行内 UTF-16 偏移计（标记全是 ASCII，跟字符数一致）
        var marker = NSRange(location: 0, length: 0)
        /// 行首空白里凑满一级的整块（一级 = 两格，制表符算两格），按行内偏移计。
        /// 这些块要整段藏掉：留着空格再靠段落样式往里排，一级就变成两级的宽度了。
        /// 不满一级的零头（比如三个空格里的最后一个）留在原地，那是用户手打的间隔。
        var indentChunks: [NSRange] = []
        var depth: Int { indentChunks.count }
    }

    struct InlineMark {
        var inner = NSRange()
        var delims: [NSRange] = []
        var bold = false
        var italic = false
        var mono = false
        var strike = false
    }

    static func headingSize(_ base: CGFloat, _ level: Int) -> CGFloat {
        base + (level == 1 ? 5 : level == 2 ? 3 : 1)
    }

    /// 一级缩进占两格。缩进要存成空格而不是制表符：列表续行、页边符号的位置、卡片预览
    /// 的对齐全按格算，混进制表符的话三处会各数出不一样的宽度。
    static let indentCols = 2
    /// 再深就只往右挪不认层级了，免得把正文挤成一条竖线
    static let maxDepth = 6

    /// 卡片预览问「这一行在第几级上」，和编辑器数的是同一套：两格一级，制表符顶两格
    static func depth(ofLine raw: String) -> Int { classify(raw).depth }

    static func forEachParagraph(_ ns: NSString, _ body: (NSRange, String) -> Void) {
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            body(para, ns.substring(with: para))
            loc = max(NSMaxRange(para), loc + 1)
        }
    }

    /// 段落区间含结尾换行，去掉换行才是这一行的实际文字
    static func contentRange(_ ns: NSString, _ para: NSRange) -> NSRange {
        var len = para.length
        if len > 0 {
            let last = ns.character(at: para.location + len - 1)
            if last == 0x0A || last == 0x0D { len -= 1 }
        }
        return NSRange(location: para.location, length: len)
    }

    static func classify(_ raw: String) -> LineInfo {
        let ns = raw as NSString
        var info = LineInfo()
        var lead = 0
        var cols = 0
        var chunkStart = 0
        var chunks: [NSRange] = []
        while lead < ns.length {
            let c = ns.character(at: lead)
            guard c == 0x20 || c == 0x09 else { break }
            cols += c == 0x09 ? Self.indentCols : 1
            lead += 1
            if cols >= Self.indentCols, chunks.count < Self.maxDepth {
                chunks.append(NSRange(location: chunkStart, length: lead - chunkStart))
                cols = 0
                chunkStart = lead
            }
        }
        // 整行只有空白：没有正文可挂，层级留着也排不出东西
        guard lead < ns.length else { return info }
        info.indentChunks = chunks
        let t = Array(raw.dropFirst(lead))

        if t.count >= 3, t[0] == "`", t[1] == "`", t[2] == "`" {
            info.kind = .fence
            info.marker = NSRange(location: 0, length: ns.length)
            return info
        }
        let s = String(t)
        if s == "---" || s == "***" || s == "___" {
            info.kind = .divider
            info.marker = NSRange(location: lead, length: s.count)
            return info
        }
        var hashes = 0
        while hashes < 3, hashes < t.count, t[hashes] == "#" { hashes += 1 }
        if hashes > 0, hashes < t.count, t[hashes] == " " {
            info.kind = .heading(hashes)
            info.marker = NSRange(location: lead, length: hashes + 1)
            return info
        }
        if t.count >= 6, t[0] == "-", t[1] == " ", t[2] == "[",
           t[3] == " " || t[3] == "x" || t[3] == "X", t[4] == "]", t[5] == " " {
            info.kind = .todo(t[3] != " ")
            info.marker = NSRange(location: lead, length: 6)
            return info
        }
        if t.count >= 2, t[1] == " ", t[0] == "-" || t[0] == "*" || t[0] == "+" {
            info.kind = .bullet
            info.marker = NSRange(location: lead, length: 2)
            return info
        }
        var digits = 0
        while digits < t.count, t[digits].isNumber, t[digits].isASCII { digits += 1 }
        if digits > 0, digits + 1 < t.count, t[digits] == ".", t[digits + 1] == " " {
            info.kind = .numbered(String(t[0..<digits]))
            info.marker = NSRange(location: lead, length: digits + 2)
            return info
        }
        if t[0] == ">" {
            info.kind = .quote
            info.marker = NSRange(location: lead, length: t.count > 1 && t[1] == " " ? 2 : 1)
            return info
        }
        return info
    }

    private struct Rule {
        var pattern: String
        var bold = false, italic = false, mono = false, strike = false
    }

    private static let rules: [Rule] = [
        Rule(pattern: "\\*\\*([+\\s\\S]+?)\\*\\*", bold: true),
        Rule(pattern: "__([+\\s\\S]+?)__", bold: true),
        Rule(pattern: "~~([+\\s\\S]+?)~~", strike: true),
        Rule(pattern: "`([^`\\n]+)`", mono: true),
        Rule(pattern: "(?<!\\*)\\*([^*\\n]+?)\\*(?!\\*)", italic: true),
        Rule(pattern: "(?<!_)_([^_\\n]+?)_(?!_)", italic: true),
    ]

    private static let compiled: [(NSRegularExpression, Rule)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule) }
    }

    static func inlineMarks(_ ns: NSString, in range: NSRange) -> [InlineMark] {
        let text = ns.substring(with: range)
        let haystack = text as NSString
        var out: [InlineMark] = []
        var taken = IndexSet()
        for (regex, rule) in compiled {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: haystack.length)) { match, _, _ in
                guard let match, match.numberOfRanges == 2 else { return }
                let inner = match.range(at: 1)
                guard inner.location != NSNotFound, inner.length > 0 else { return }
                let whole = match.range(at: 0)
                var overlap = IndexSet(integersIn: whole.location..<NSMaxRange(whole))
                overlap.formIntersection(taken)
                guard overlap.isEmpty else { return }
                taken.formUnion(IndexSet(integersIn: whole.location..<NSMaxRange(whole)))
                let shift = range.location
                var mark = InlineMark()
                mark.inner = NSRange(location: inner.location + shift, length: inner.length)
                mark.bold = rule.bold
                mark.italic = rule.italic
                mark.mono = rule.mono
                mark.strike = rule.strike
                let head = NSRange(location: whole.location + shift, length: inner.location - whole.location)
                let tail = NSRange(location: NSMaxRange(inner) + shift,
                                   length: NSMaxRange(whole) - NSMaxRange(inner))
                mark.delims = [head, tail]
                out.append(mark)
            }
        }
        return out
    }
}

// MARK: - 段落样式

enum MarkdownStyle {
    /// 一级缩进往右挪多少点。页边符号也按这个步进走，两边才不会错位
    static let indentStep: CGFloat = 16

    /// 各类别正文起排的位子（第 0 级）。符号就画在它前面那条页边里
    static func baseIndent(_ kind: MarkdownSyntax.LineKind) -> CGFloat {
        switch kind {
        case .bullet: return 20
        case .todo: return 23
        case .numbered: return 27
        case .quote: return 15
        case .code: return 8
        case .plain, .fence, .divider, .heading: return 0
        }
    }

    /// 排版时每段都要取一份段落样式，同样的 (类型, 字号, 层级) 反复算没意义；
    /// 更要紧的是复用同一个对象，属性比对才知道「这里没变」，不必重排行。
    private static var cache: [String: NSParagraphStyle] = [:]

    /// 缓存键只取影响排版的那部分：序号「12.」和「1.」用的是同一份样式，
    /// 直接把 LineKind 插进字符串会把每个数字都存一份。
    private static func cacheKey(_ kind: MarkdownSyntax.LineKind, _ size: CGFloat, _ depth: Int) -> String {
        let tag: String
        switch kind {
        case .plain: tag = "p"
        case let .heading(level): tag = "h\(level)"
        case .bullet: tag = "b"
        case .todo: tag = "t"
        case .numbered: tag = "n"
        case .quote: tag = "q"
        case .divider: tag = "d"
        case .code: tag = "c"
        case .fence: tag = "f"
        }
        return "\(tag)|\(size)|\(depth)"
    }

    static func para(_ kind: MarkdownSyntax.LineKind, size: CGFloat, depth: Int = 0) -> NSParagraphStyle {
        let key = cacheKey(kind, size, depth)
        if let cached = cache[key] { return cached }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = size * 0.22
        // 缩进就是页边符号的位置：正文从 firstLineHeadIndent 起排，符号画在页边那条里，
        // 换行继续排也要对齐正文，所以 headIndent 跟它取一样。
        let indent = baseIndent(kind) + CGFloat(depth) * indentStep
        switch kind {
        case .bullet, .todo, .numbered, .quote, .code:
            p.firstLineHeadIndent = indent
            p.headIndent = indent
        case .divider:
            // 正文（---）被藏成 0.1pt，行高得手动撑回来，不然分隔线挤成一条缝
            p.minimumLineHeight = size
            p.maximumLineHeight = size
            p.lineSpacing = size * 0.3
            p.firstLineHeadIndent = indent
            p.headIndent = indent
        case let .heading(level):
            p.lineSpacing = size * (level == 1 ? 0.34 : 0.24)
            p.firstLineHeadIndent = indent
            p.headIndent = indent
        case .plain, .fence:
            p.firstLineHeadIndent = indent
            p.headIndent = indent
        }
        // 字号只有设置里那几档，层级封顶 6，缓存撑不爆
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
        cache[key] = p
        return p
    }
}
