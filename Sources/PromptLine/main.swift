import AppKit
import PromptLineCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = InputPanel()
    private var hotkeys: [GlobalHotkey] = []
    private var statusItem: NSStatusItem?
    private var target: NSRunningApplication?

    private var history: HistoryStore?
    private let draft = DraftStore(fileURL: Storage.draftFile)
    private var pendingDraftSave: DispatchWorkItem?
    private var navigator = HistoryNavigator()
    /// 検索中だけ非 nil。履歴送りと一覧表示の対象が全履歴から絞り込み結果に替わる
    private var searchResults: [HistoryItem]?
    private var currentItems: [HistoryItem] { searchResults ?? history?.items ?? [] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 許可が無ければ初回だけシステムの案内を出す
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        registerHotkeys()
        loadStorage()

        panel.textView.onPaste = { [weak self] in self?.pasteAndClose() }
        panel.textView.onClose = { [weak self] in self?.hidePanel() }
        panel.textView.onHistoryOlder = { [weak self] in self?.navigateHistory(older: true) }
        panel.textView.onHistoryNewer = { [weak self] in self?.navigateHistory(older: false) }
        panel.textView.onSearch = { [weak self] in self?.beginSearch() }
        panel.historyList.onQueryChange = { [weak self] in self?.search($0) }
        panel.onSearchCancel = { [weak self] in self?.endSearch(keepingText: false) }
        panel.onSearchAccept = { [weak self] in self?.endSearch(keepingText: true) }
        // 履歴を送った後に手で編集したら、その文章が新しい入力になる(送りは終わる)。
        // string への代入では通知は出ないので、履歴送り自体はここへ来ない
        NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: panel.textView, queue: .main
        ) { [weak self] _ in
            self?.navigator.reset()
            self?.refreshHistoryList()
            self?.scheduleDraftSave()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "PL"
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Prompt Line", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        flushDraft()
    }

    private func registerHotkeys() {
        var specs = HotkeySpec.defaults
        if let override = option("hotkey", env: "PROMPT_LINE_HOTKEY") {
            // 例: "ctrl+opt+p,cmd+shift+f12"
            let parsed = override.split(separator: ",").map { HotkeySpec(String($0)) }
            guard !parsed.isEmpty, !parsed.contains(where: { $0 == nil }) else {
                fputs("PROMPT_LINE_HOTKEY を解釈できません: \(override)\n", stderr)
                exit(1)
            }
            specs = parsed.compactMap { $0 }
        }
        for spec in specs {
            guard let hotkey = GlobalHotkey(spec) else {
                fputs("ホットキーを登録できません(他のアプリが同じ組み合わせを使用中): \(spec)\n", stderr)
                exit(1)
            }
            hotkey.onPress = { [weak self] in self?.toggle() }
            hotkeys.append(hotkey)
        }
    }

    /// 履歴が読めなくてもパネルは使えるようにし、貼り付けだけは続ける
    private func loadStorage() {
        do {
            history = try HistoryStore(fileURL: Storage.historyFile)
            debugLog("history loaded: \(history?.items.count ?? 0) items, skipped \(history?.skippedLines ?? 0)")
        } catch {
            fputs("履歴を読めません(履歴なしで続けます): \(error)\n", stderr)
        }
        if let saved = draft.load() { panel.textView.string = saved.text }
    }

    private func toggle() {
        debugLog("toggle visible=\(panel.isVisible) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        if panel.isVisible {
            hidePanel()
            return
        }
        // 自分自身が前面のことは無いが、念のため貼り付け先にしない
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? target : front
        refreshHistoryList()
        panel.centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        // 前面アプリが貼り付け先のままだと、Raycast のクリップボード履歴などが入力欄でなくそのアプリへ貼る
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(panel.textView)
    }

    /// 閉じても下書きは残す(貼り付けたときだけ消える)。履歴を送っている途中なら、送る前の入力へ戻す
    private func hidePanel() {
        if searchResults != nil { endSearch(keepingText: false) }
        if navigator.isNavigating { show(navigator.stash) }
        navigator.reset()
        refreshHistoryList()
        panel.orderOut(nil)
        flushDraft()
        // 自分が前面のまま閉じると、キー入力の行き先が無くなる
        if let target, !target.isTerminated { target.activate() }
    }

    private func navigateHistory(older: Bool) {
        guard !panel.textView.hasMarkedText() else { return }
        let items = currentItems
        let text = older
            ? navigator.older(in: items, current: panel.textView.string)
            : navigator.newer(in: items)
        if let text { show(text) }
        refreshHistoryList()
    }

    private func refreshHistoryList() {
        panel.historyList.update(items: currentItems, selected: navigator.isNavigating ? navigator.index : nil)
    }

    // MARK: - 検索

    private func beginSearch() {
        guard let history, searchResults == nil else { return }
        // 履歴を送っている途中なら、送る前の入力へ戻してから検索を始める(戻さないと下書きを失う)
        if navigator.isNavigating { show(navigator.stash) }
        navigator.reset()
        searchResults = history.items
        panel.beginSearch()
        refreshHistoryList()
    }

    /// 絞り込み直すと送り位置が無効になるので、入力は送り始める前の文章へ戻す
    private func search(_ query: String) {
        guard let history, searchResults != nil else { return }
        if navigator.isNavigating { show(navigator.stash) }
        navigator.reset()
        searchResults = HistorySearch.filter(history.items, query: query)
        refreshHistoryList()
    }

    /// keepingText: 送っている履歴の文章を入力として残す(Enter)。false なら送る前の文章へ戻す(Esc)
    private func endSearch(keepingText: Bool) {
        guard searchResults != nil else { return }
        if !keepingText, navigator.isNavigating { show(navigator.stash) }
        navigator.reset()
        searchResults = nil
        panel.endSearch()
        refreshHistoryList()
        scheduleDraftSave()
    }

    /// 入力欄の中身を差し替えてカーソルを末尾へ置く
    private func show(_ text: String) {
        panel.textView.string = text
        panel.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        panel.textView.scrollRangeToVisible(panel.textView.selectedRange())
    }

    private func pasteAndClose() {
        let text = panel.textView.string
        debugLog("pasteAndClose text=\(text.debugDescription) target=\(target?.localizedName ?? "nil") trusted=\(AXIsProcessTrusted())")
        guard !text.isEmpty else { return }
        // 送れない状態では、履歴・下書き・入力のどれも消さずにパネルを開いたままにする
        guard AXIsProcessTrusted(), let target, !target.isTerminated else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            NSSound.beep()
            return
        }

        do {
            try history?.add(text: text, appName: target.localizedName)
        } catch {
            fputs("履歴へ追記できません(貼り付けは続けます): \(error)\n", stderr)
        }
        pendingDraftSave?.cancel()
        draft.clear()
        navigator.reset()
        if searchResults != nil {
            searchResults = nil
            panel.endSearch()
            refreshHistoryList()
        }
        Paster.paste(text, into: target, after: panel)
        panel.textView.string = ""
    }

    // MARK: - 下書き

    /// 変換中の未確定文字は保存しない。確定後の変更通知か、閉じる・終了の時点で保存される
    private func scheduleDraftSave() {
        pendingDraftSave?.cancel()
        guard !panel.textView.hasMarkedText() else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushDraft() }
        pendingDraftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushDraft() {
        pendingDraftSave?.cancel()
        pendingDraftSave = nil
        guard !panel.textView.hasMarkedText() else { return }
        // 履歴を送っている間に終了しても、履歴の文章ではなく送る前の入力を下書きに残す
        let text = navigator.isNavigating ? navigator.stash : panel.textView.string
        do {
            try draft.save(text: text)
        } catch {
            fputs("下書きを保存できません: \(error)\n", stderr)
        }
    }
}

func debugLog(_ message: String) {
    // 貼り付けた本文を書くので、履歴・下書きと同じく新規作成は 0600 にする
    guard let path = ProcessInfo.processInfo.environment["PROMPT_LINE_LOG"],
          let handle = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) ? FileHandle(forWritingAtPath: path) : nil)
    else { return }
    handle.seekToEndOfFile()
    handle.write(Data((message + "\n").utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
