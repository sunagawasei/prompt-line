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
    /// 文字数の表示とプレースホルダの更新用。string への代入でも呼ぶ(代入では NSText.didChangeNotification は出ない)
    var onContentChange: (() -> Void)?

    override var string: String {
        didSet { contentChanged() }
    }

    override func didChangeText() {
        super.didChangeText()
        contentChanged()
    }

    private func contentChanged() {
        needsDisplay = true
        onContentChange?()
    }

    /// 空のときだけ薄い案内を、文字が置かれる位置に描く。変換中は未確定文字があるので描かない
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: "プロンプトを入力…", attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: Theme.dimText.withAlphaComponent(0.6),
        ]).draw(at: NSPoint(x: origin.x + padding, y: origin.y))
    }

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

/// 履歴の 1 行。文章を左に、入力した時刻を右端に出す。選択中は角丸の背景と左のアクセント線で強調する
final class HistoryRowView: NSView {
    static let height: CGFloat = 24
    /// 文章の左端を入力欄(textContainerInset 20 + lineFragmentPadding 5)に揃えるための、行の左余白。
    /// 一覧の左右余白 6 を引いてある
    static let textInset: CGFloat = 19

    private let title = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let accentBar = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Theme.accent.cgColor
        accentBar.layer?.cornerRadius = 1.25
        accentBar.isHidden = true
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        age.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        age.textColor = Theme.dimText.withAlphaComponent(0.7)
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [accentBar, title, age] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            accentBar.widthAnchor.constraint(equalToConstant: 2.5),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            age.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            age.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(title text: NSAttributedString, age ageText: String, isSelected: Bool) {
        title.attributedStringValue = text
        age.stringValue = ageText
        layer?.backgroundColor = isSelected ? Theme.selectedRow.cgColor : NSColor.clear.cgColor
        accentBar.isHidden = !isSelected
        age.textColor = Theme.dimText.withAlphaComponent(isSelected ? 0.9 : 0.7)
    }
}

/// 入力欄の下に出す履歴(新しい順)。履歴を送っている間は選択中の行を強調し、その前後を見せる
final class HistoryListView: NSView, NSTextFieldDelegate {
    static let rows = 6
    static let headerHeight: CGFloat = 22
    static let padding: CGFloat = 6
    static var height: CGFloat { headerHeight + CGFloat(rows) * HistoryRowView.height + padding * 2 }

    private let rowViews: [HistoryRowView]
    private let headerTitle = NSTextField(labelWithString: "履歴")
    private let headerCount = NSTextField(labelWithString: "")
    /// 検索中だけ、先頭の行に重ねて出す
    let searchField = NSTextField()
    private let searchIcon = NSImageView()
    var onQueryChange: ((String) -> Void)?
    var isSearching = false {
        didSet {
            searchField.isHidden = !isSearching
            searchIcon.isHidden = !isSearching
            rowViews[0].isHidden = isSearching
            headerTitle.stringValue = isSearching ? "検索結果" : "履歴"
        }
    }

    override init(frame: NSRect) {
        rowViews = (0..<Self.rows).map { _ in HistoryRowView() }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sunkenTint.cgColor

        let header = NSView()
        for label in [headerTitle, headerCount] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.dimText
            label.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(label)
        }
        headerCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: HistoryRowView.textInset),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -1),
            headerCount.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            headerCount.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -1),
        ])

        let stack = NSStackView(views: [header] + rowViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.hairline.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
        ])
        for view in [header] + rowViews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        searchIcon.contentTintColor = Theme.dimText
        searchIcon.isHidden = true
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchIcon)

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
        let firstRow = rowViews[0]
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: firstRow.leadingAnchor, constant: HistoryRowView.textInset + Self.padding - 1),
            searchIcon.centerYAnchor.constraint(equalTo: firstRow.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: firstRow.centerYAnchor),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// selected が nil のときは先頭から並べる。選択行は窓の中ほどに寄せる。検索中は先頭の行が検索欄になる
    func update(items: [HistoryItem], selected: Int?) {
        if isSearching {
            headerCount.stringValue = "\(items.count) 件"
        } else if let selected {
            headerCount.stringValue = "\(selected + 1) / \(items.count)"
        } else {
            headerCount.stringValue = "\(items.count) 件"
        }
        let reserved = isSearching ? 1 : 0
        let capacity = Self.rows - reserved
        let keywords = isSearching ? HistorySearch.keywords(searchField.stringValue) : []
        let start = selected.map { min(max(0, $0 - capacity / 2), max(0, items.count - capacity)) } ?? 0
        let now = Date()
        for (slot, row) in rowViews.enumerated() where slot >= reserved {
            let index = start + slot - reserved
            guard index < items.count else {
                let hint = isSearching && items.isEmpty && slot == reserved ? Self.hint("一致する履歴がありません") : NSAttributedString()
                row.show(title: hint, age: "", isSelected: false)
                continue
            }
            let item = items[index]
            let oneLine = item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            let isSelected = index == selected
            row.show(
                title: Self.row(oneLine, color: isSelected ? Theme.text : Theme.dimText, keywords: keywords),
                age: AgeLabel.text(forTimestamp: item.timestamp, now: now),
                isSelected: isSelected)
        }
    }

    /// keywords にかかった部分は色と太さで目立たせる。最初の一致が行の途中で見切れるなら、その手前から見せる
    private static func row(_ text: String, color: NSColor, keywords: [String] = []) -> NSAttributedString {
        var shown = text
        let firstMatch = keywords.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        if let firstMatch, text.distance(from: text.startIndex, to: firstMatch) > 30,
           let from = text.index(firstMatch, offsetBy: -12, limitedBy: text.startIndex) {
            shown = "…" + text[from...]
        }
        let result = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: color,
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

/// 下端に常時出す、全操作のキー案内
final class ShortcutFooterView: NSView {
    static let height: CGFloat = 30
    private static let hints = ["⌘↵ 貼り付け", "⌃J/K 履歴", "⌘F 検索", "esc 閉じる"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sunkenTint.cgColor
        let labels = Self.hints.map { hint -> NSTextField in
            let label = NSTextField(labelWithString: hint)
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.dimText
            return label
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.hairline.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HistoryRowView.textInset + HistoryListView.padding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// 貼り付け先アプリを前面のまま、キー入力だけを受ける浮動パネル
final class InputPanel: NSPanel {
    static let editorHeight: CGFloat = 190
    static let size = NSSize(width: 640, height: editorHeight + HistoryListView.height + ShortcutFooterView.height)
    let textView = InputTextView()
    let historyList = HistoryListView()
    private let countLabel = NSTextField(labelWithString: "")
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
        // 配色はダーク固定。システムの外観がライトでも、ぼかしと文字色が崩れないようにする
        appearance = NSAppearance(named: .darkAqua)

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = Theme.hairline.cgColor
        contentView = glass

        let tint = NSView(frame: glass.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = Theme.glassTint.cgColor
        glass.addSubview(tint)

        let footer = ShortcutFooterView(frame: NSRect(x: 0, y: 0, width: Self.size.width, height: ShortcutFooterView.height))
        footer.autoresizingMask = [.width]
        glass.addSubview(footer)

        let listHeight = HistoryListView.height
        historyList.frame = NSRect(x: 0, y: ShortcutFooterView.height, width: Self.size.width, height: listHeight)
        historyList.autoresizingMask = [.width]
        glass.addSubview(historyList)

        let editorY = ShortcutFooterView.height + listHeight
        let scroll = NSScrollView(frame: NSRect(x: 0, y: editorY, width: Self.size.width, height: Self.size.height - editorY))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 0)
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
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        scroll.documentView = textView
        glass.addSubview(scroll)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.dimText.withAlphaComponent(0.8)
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: Self.size.width - 116, y: editorY + 4, width: 100, height: 14)
        countLabel.autoresizingMask = [.minXMargin]
        glass.addSubview(countLabel)
        textView.onContentChange = { [weak self] in self?.updateCount() }
        updateCount()
    }

    override var canBecomeKey: Bool { true }

    private func updateCount() {
        let count = textView.string.count
        countLabel.stringValue = count == 0 ? "" : "\(count) 文字"
    }

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
