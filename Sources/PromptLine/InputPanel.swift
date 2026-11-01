import AppKit
import Carbon.HIToolbox
import PromptLineCore

extension NSEvent {
    /// ショートカットの判定に使う修飾キー。Caps Lock・テンキー・Fn は無視する
    /// (deviceIndependentFlagsMask のままだと、Caps Lock 中は Esc も Cmd+Enter も一致しない)
    var shortcutFlags: NSEvent.ModifierFlags { modifierFlags.intersection([.command, .shift, .control, .option]) }
}

/// 入力欄。IME の変換中(未確定文字がある間)は、確定・取消のキーを IME に渡す。
final class InputTextView: NSTextView {
    var onPaste: (() -> Void)?
    var onClose: (() -> Void)?
    /// Ctrl+j は古い方へ、Ctrl+k は新しい方へ(Electron 版と同じ割り当て)
    var onHistoryOlder: (() -> Void)?
    var onHistoryNewer: (() -> Void)?
    var onSearch: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { return super.keyDown(with: event) }
        let flags = event.shortcutFlags
        switch (Int(event.keyCode), flags) {
        case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command):
            onPaste?()
        case (kVK_Escape, []):
            onClose?()
        case (kVK_ANSI_J, .control):
            onHistoryOlder?()
        case (kVK_ANSI_K, .control):
            onHistoryNewer?()
        default:
            super.keyDown(with: event)
        }
    }

    /// アプリを前面にしないパネルでは、メインメニュー経由の編集ショートカットが届かないので自前で受ける
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        let flags = event.shortcutFlags
        if flags == .command {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: onPaste?(); return true
            case kVK_ANSI_V: paste(nil); return true
            case kVK_ANSI_C: copy(nil); return true
            case kVK_ANSI_X: cut(nil); return true
            case kVK_ANSI_A: selectAll(nil); return true
            case kVK_ANSI_Z: undoManager?.undo(); return true
            case kVK_ANSI_F: onSearch?(); return true
            default: break
            }
        } else if flags == [.command, .shift], Int(event.keyCode) == kVK_ANSI_Z {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 入力欄の下に出す履歴(新しい順)。履歴を送っている間は選択中の行を強調し、その前後を見せる
final class HistoryListView: NSView, NSTextFieldDelegate {
    static let rows = 6
    static let rowHeight: CGFloat = 22
    static var height: CGFloat { CGFloat(rows) * rowHeight + 8 }

    private let labels: [NSTextField]
    /// 検索中だけ、先頭の行に重ねて出す
    let searchField = NSTextField()
    var onQueryChange: ((String) -> Void)?
    var isSearching = false {
        didSet {
            searchField.isHidden = !isSearching
            labels[0].isHidden = isSearching
        }
    }

    override init(frame: NSRect) {
        labels = (0..<Self.rows).map { _ in
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.drawsBackground = true
            label.backgroundColor = .clear
            label.heightAnchor.constraint(equalToConstant: HistoryListView.rowHeight).isActive = true
            return label
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sunkenBackground.cgColor
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.detachesHiddenViews = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.border.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        for label in labels { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = Theme.text
        searchField.placeholderAttributedString = NSAttributedString(string: "検索(スペース区切りで絞り込み)", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.dimText,
        ])
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.delegate = self
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 19),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: labels[0].topAnchor),
            searchField.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// selected が nil のときは先頭から並べる。選択行は窓の中ほどに寄せる。検索中は先頭の行が検索欄になる
    func update(items: [HistoryItem], selected: Int?) {
        let reserved = isSearching ? 1 : 0
        let capacity = Self.rows - reserved
        let keywords = isSearching ? HistorySearch.keywords(searchField.stringValue) : []
        let start = selected.map { min(max(0, $0 - capacity / 2), max(0, items.count - capacity)) } ?? 0
        for (slot, label) in labels.enumerated() where slot >= reserved {
            let index = start + slot - reserved
            guard index < items.count else {
                label.attributedStringValue = isSearching && items.isEmpty && slot == reserved ? Self.hint("一致する履歴がありません") : NSAttributedString()
                label.backgroundColor = .clear
                continue
            }
            let oneLine = items[index].text.replacingOccurrences(of: "\n", with: " ⏎ ")
            let isSelected = index == selected
            label.attributedStringValue = Self.row(oneLine, color: isSelected ? Theme.text : Theme.dimText, keywords: keywords)
            label.backgroundColor = isSelected ? Theme.activeLine : .clear
        }
    }

    /// 文字の左端を入力欄(textContainerInset 12 + lineFragmentPadding 5)に揃える。
    /// keywords にかかった部分は色と太さで目立たせる。最初の一致が行の途中で見切れるなら、その手前から見せる
    private static func row(_ text: String, color: NSColor, keywords: [String] = []) -> NSAttributedString {
        var shown = text
        let firstMatch = keywords.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        if let firstMatch, text.distance(from: text.startIndex, to: firstMatch) > 30,
           let from = text.index(firstMatch, offsetBy: -12, limitedBy: text.startIndex) {
            shown = "…" + text[from...]
        }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 17
        style.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: style,
        ])
        let nsShown = shown as NSString
        for keyword in keywords {
            var range = NSRange(location: 0, length: nsShown.length)
            while true {
                let found = nsShown.range(of: keyword, options: .caseInsensitive, range: range)
                if found.location == NSNotFound { break }
                result.addAttributes([.foregroundColor: Theme.match, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)], range: found)
                let next = found.location + max(found.length, 1)
                range = NSRange(location: next, length: nsShown.length - next)
            }
        }
        return result
    }

    private static func hint(_ text: String) -> NSAttributedString { row(text, color: Theme.dimText) }
}

/// 貼り付け先アプリを前面のまま、キー入力だけを受ける浮動パネル
final class InputPanel: NSPanel {
    static let size = NSSize(width: 640, height: 220 + HistoryListView.height)
    let textView = InputTextView()
    let historyList = HistoryListView()
    var onSearchCancel: (() -> Void)?
    var onSearchAccept: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = Theme.background.cgColor
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.borderWidth = 1
        contentView?.layer?.borderColor = Theme.border.cgColor
        contentView?.layer?.masksToBounds = true

        let listHeight = HistoryListView.height
        historyList.frame = NSRect(x: 0, y: 0, width: Self.size.width, height: listHeight)
        historyList.autoresizingMask = [.width]
        contentView?.addSubview(historyList)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: listHeight, width: Self.size.width, height: Self.size.height - listHeight))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.frame = scroll.bounds
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.selectionBackground,
            .foregroundColor: Theme.selectionForeground,
        ]
        scroll.scrollerKnobStyle = .light
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        scroll.documentView = textView
        contentView?.addSubview(scroll)
    }

    override var canBecomeKey: Bool { true }

    func beginSearch() {
        historyList.isSearching = true
        historyList.searchField.stringValue = ""
        makeFirstResponder(historyList.searchField)
        (historyList.searchField.currentEditor() as? NSTextView)?.insertionPointColor = Theme.caret
    }

    func endSearch() {
        historyList.isSearching = false
        makeFirstResponder(textView)
    }

    /// 検索欄にフォーカスがある間のキー。履歴送り・確定・取消・貼り付けは入力欄と同じ手で押せるようにする
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, historyList.isSearching,
           let editor = firstResponder as? NSTextView, editor !== textView, !editor.hasMarkedText(),
           handleSearchKey(event, editor: editor) { return }
        super.sendEvent(event)
    }

    private func handleSearchKey(_ event: NSEvent, editor: NSTextView) -> Bool {
        let flags = event.shortcutFlags
        switch (Int(event.keyCode), flags) {
        case (kVK_ANSI_J, .control): textView.onHistoryOlder?()
        case (kVK_ANSI_K, .control): textView.onHistoryNewer?()
        case (kVK_Escape, []): onSearchCancel?()
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): onSearchAccept?()
        case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command): textView.onPaste?()
        // アプリを前面にしないので、編集ショートカットは自前で受ける
        case (kVK_ANSI_V, .command): editor.paste(nil)
        case (kVK_ANSI_C, .command): editor.copy(nil)
        case (kVK_ANSI_X, .command): editor.cut(nil)
        case (kVK_ANSI_A, .command): editor.selectAll(nil)
        case (kVK_ANSI_Z, .command): editor.undoManager?.undo()
        default: return false
        }
        return true
    }

    /// マウスのあるディスプレイの上寄り中央へ置く(中央よりやや上は、ランチャー類で見やすい位置)
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.maxY - frame.height * 0.35 - Self.size.height / 2))
    }
}
