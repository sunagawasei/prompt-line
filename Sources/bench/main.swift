// Electron 版・Swift 版に同じ手順で流す計測ハーネス。
//   bench show [--runs N] [--owner "Prompt Line"]   ホットキー送信→パネルが画面に出るまでの ms
//   bench rss  [--match "/Applications/Prompt Line.app"]  コマンドがこのパスで始まるプロセス群の RSS 合計(MB)
// 送信した Cmd+Shift+Space と Escape は実際に前面アプリへ届くので、静かなときに流す。
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func arg(_ name: String, default value: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return value }
    return args[i + 1]
}

/// 実キーボードと同じ順(修飾キー押下→キー→修飾キー解放)で、セッション層へ送る。
/// Carbon のホットキーは HID 層へ直接送ったイベントには反応しない。
/// 戻り値は、キー本体を押した時刻(遅延の起点)
@discardableResult
func post(key: CGKeyCode, flags: CGEventFlags) -> DispatchTime {
    let source = CGEventSource(stateID: .hidSystemState)
    let modifiers: [(flag: CGEventFlags, code: CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
    ].filter { flags.contains($0.flag) }
    func send(_ code: CGKeyCode, down: Bool, _ f: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = f
        event?.post(tap: .cgSessionEventTap)
        usleep(10_000)
    }
    var held: CGEventFlags = []
    for m in modifiers { held.insert(m.flag); send(m.code, down: true, held) }
    let pressed = DispatchTime.now()
    send(key, down: true, flags)
    send(key, down: false, flags)
    for m in modifiers.reversed() { held.remove(m.flag); send(m.code, down: false, held) }
    return pressed
}

/// owner のウィンドウのうち、入力パネルらしい大きさ(幅300以上)のものが画面上にあるか
func panelVisible(owner: String) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { w in
        guard (w[kCGWindowOwnerName as String] as? String) == owner,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return false }
        return (b["Width"] ?? 0) >= 300
    }
}

func waitUntil(timeout: Double, _ cond: () -> Bool) -> Double? {
    let start = DispatchTime.now()
    while true {
        if cond() { return elapsedMs(since: start) }
        if elapsedMs(since: start) > timeout * 1000 { return nil }
        usleep(1_000)
    }
}

func elapsedMs(since t: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
}

func summarize(_ values: [Double]) -> String {
    let s = values.sorted()
    let median = s[s.count / 2]
    return String(format: "n=%d min=%.0f median=%.0f max=%.0f ms", s.count, s.first!, median, s.last!)
}

func type(_ text: String) {
    for ch in text.utf16.map({ [$0] }) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: ch.count, unicodeString: ch)
            event?.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }
}

func flags(from text: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for part in text.lowercased().split(separator: "+") {
        switch part {
        case "cmd": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "alt": f.insert(.maskAlternate)
        case "ctrl": f.insert(.maskControl)
        default: break
        }
    }
    return f
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func output(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - テスト専用インスタンス(利用者が使っているアプリとは別のホットキー・データ置き場で動かす)

let testHotkey = "ctrl+opt+p"
let testHotkeyFlags: CGEventFlags = [.maskControl, .maskAlternate]
let testHotkeyKey: CGKeyCode = 35

func launchInstance(app: String, dataDir: String) {
    shell("/usr/bin/open", ["-n", app, "--args", "--hotkey", testHotkey, "--data-dir", dataDir])
    sleep(2)
}

func instancePID(dataDir: String) -> pid_t? {
    pid_t(output("/usr/bin/pgrep", ["-f", "--", "--data-dir \(dataDir)"]).split(separator: "\n").first.map(String.init) ?? "")
}

func stopInstance(dataDir: String) {
    shell("/usr/bin/pkill", ["-f", "--", "--data-dir \(dataDir)"])
    _ = waitUntil(timeout: 5) { instancePID(dataDir: dataDir) == nil }
}

/// 入力パネルの入力欄の中身を、アクセシビリティ API で外から読む
func readPanelText(dataDir: String) -> String? {
    guard let pid = instancePID(dataDir: dataDir) else { return nil }
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
    return value as? String
}

/// 入力パネルの入力欄(AXTextArea)の中身。検索欄にフォーカスがあっても読める
func readInputText(dataDir: String) -> String? {
    guard let pid = instancePID(dataDir: dataDir) else { return nil }
    func find(_ element: AXUIElement, depth: Int) -> String? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXTextAreaRole as String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            return value as? String
        }
        guard depth < 8 else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
    for window in (windows as? [AXUIElement]) ?? [] {
        if let found = find(window, depth: 0) { return found }
    }
    return nil
}

func makeTempDir() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pl-e2e-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// キーを実機の入力経路で送るテストなので、実行中に手元のキーボードに触れると入力が混ざって失敗する
if let name = CommandLine.arguments.dropFirst().first, name == "snap" || name.hasPrefix("e2e") {
    print("\(name): 実行中はキーボードとマウスに触れないでください")
    _ = shell("/usr/bin/osascript", ["-e", "display notification \"テスト中はキーボードに触れないでください\" with title \"Prompt Line bench\""])
}

switch CommandLine.arguments.dropFirst().first {
case "cold":
    // 例: bench cold --app "/Applications/Prompt Line.app" --proc "Prompt Line" --runs 5
    // アプリを終了→起動し、ホットキーを --retry-ms(+送信に約60ms)ごとに送り直して、最初にパネルが出るまでを測る
    guard AXIsProcessTrusted() else { print("Accessibility 許可が無いので実行できません"); exit(1) }
    let appPath = arg("--app", default: "")
    let proc = arg("--proc", default: "")
    let owner = arg("--owner", default: "Prompt Line")
    let runs = Int(arg("--runs", default: "5")) ?? 5
    let mods = flags(from: arg("--mods", default: "cmd+shift"))
    let code = UInt16(arg("--key", default: "49")).map { CGKeyCode($0) } ?? 49
    guard !appPath.isEmpty, !proc.isEmpty else { print("--app と --proc が必要です"); exit(1) }
    let retryMs = Double(arg("--retry-ms", default: "450")) ?? 450
    var times: [Double] = []
    for i in 1...runs {
        shell("/usr/bin/pkill", ["-x", proc])
        guard waitUntil(timeout: 10, { shell("/usr/bin/pgrep", ["-x", proc]) != 0 }) != nil else { print("終了できません"); exit(1) }
        sleep(1)
        let t0 = DispatchTime.now()
        shell("/usr/bin/open", [appPath])
        var shown: Double?
        while elapsedMs(since: t0) < 15_000 {
            post(key: code, flags: mods)
            if waitUntil(timeout: retryMs / 1000, { panelVisible(owner: owner) }) != nil { shown = elapsedMs(since: t0); break }
        }
        guard let ms = shown else { print("run \(i): 15秒以内に表示されませんでした"); continue }
        times.append(ms)
        print(String(format: "run %d: %.0f ms", i, ms))
        usleep(300_000)
        post(key: 53, flags: [])
        _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    }
    if !times.isEmpty { print("cold: " + summarize(times)) }
case "e2e":
    // 貼り付け先役のウィンドウを前面に出し、ホットキー→入力→Cmd+Enter で本文が届くかを確かめる。
    // 例: bench e2e --mods ctrl+opt --owner PromptLine --text "テスト abc"
    guard AXIsProcessTrusted() else { print("Accessibility 許可が無いので実行できません"); exit(1) }
    let owner = arg("--owner", default: "Prompt Line")
    let mods = flags(from: arg("--mods", default: "cmd+shift"))
    let text = arg("--text", default: "テスト abc 123")
    // --app を渡すと、専用のデータ置き場で自前のインスタンスを起動し、履歴・下書きの結果まで確かめる
    let appPath = arg("--app", default: "")
    let dataDir = makeTempDir()
    if !appPath.isEmpty { launchInstance(app: appPath, dataDir: dataDir) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 500, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let target = NSTextView(frame: window.contentView!.bounds)
    window.contentView = target
    window.title = "bench paste target"
    // メニューが無いと Cmd+V が NSTextView に届かないので、貼り付け先役にも Edit メニューを置く
    let mainMenu = NSMenu()
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    app.mainMenu = mainMenu
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.global().async {
        func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }
        sleep(1)
        DispatchQueue.main.sync { window.makeFirstResponder(target) }
        let hotkeyCode = UInt16(arg("--key", default: "49")).map { CGKeyCode($0) } ?? 49
        post(key: appPath.isEmpty ? hotkeyCode : testHotkeyKey, flags: appPath.isEmpty ? mods : testHotkeyFlags)
        guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { fail("パネルが表示されない") }
        usleep(200_000)
        type(text)
        usleep(200_000)
        post(key: 36, flags: [.maskCommand, .maskAlphaShift]) // Cmd+Return(Caps Lock 中でも届く)
        guard waitUntil(timeout: 3, { !panelVisible(owner: owner) }) != nil else { fail("パネルが閉じない") }
        usleep(500_000)
        let got = DispatchQueue.main.sync { target.string }
        guard got == text else { fail("貼り付け結果が違う: \(got.debugDescription) != \(text.debugDescription)") }
        let frontIsTarget = DispatchQueue.main.sync { NSApp.isActive }
        guard frontIsTarget else { fail("貼り付け後に貼り付け先が前面でない") }
        if !appPath.isEmpty {
            let history = (try? String(contentsOfFile: dataDir + "/history.jsonl", encoding: .utf8)) ?? ""
            guard history.hasPrefix("{\"text\":\"\(text)\",\"timestamp\":"), history.hasSuffix("\n"), history.split(separator: "\n").count == 1 else {
                fail("履歴の追記が想定と違う: \(history.debugDescription)")
            }
            guard !FileManager.default.fileExists(atPath: dataDir + "/draft-swift.json") else { fail("貼り付け後に下書きが残っている") }
            stopInstance(dataDir: dataDir)
            print("PASS: 履歴に1行追記され、下書きは消えた")
        }
        print("PASS: \(text.debugDescription) が貼り付け先へ届き、パネルは閉じた")
        exit(0)
    }
    app.run()
case "e2e-draft":
    // 入力→(閉じる)→アプリ再起動→開く、で下書きが戻るかを確かめる。例: bench e2e-draft --app build/PromptLine.app
    guard AXIsProcessTrusted() else { print("Accessibility 許可が無いので実行できません"); exit(1) }
    let appPath = arg("--app", default: "")
    let owner = arg("--owner", default: "Prompt Line")
    let text = arg("--text", default: "下書き 123")
    guard !appPath.isEmpty else { print("--app が必要です"); exit(1) }
    func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }
    let dataDir = makeTempDir()
    let draftFile = dataDir + "/draft-swift.json"

    launchInstance(app: appPath, dataDir: dataDir)
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("パネルが表示されない") }
    usleep(200_000)
    type(text)
    // 入力から約 0.4 秒後に自動保存される
    guard waitUntil(timeout: 2, { FileManager.default.fileExists(atPath: draftFile) }) != nil else { stopInstance(dataDir: dataDir); fail("入力しても下書きが保存されない") }
    let mode = (try? FileManager.default.attributesOfItem(atPath: draftFile))?[.posixPermissions] as? Int
    guard mode == 0o600 else { stopInstance(dataDir: dataDir); fail("下書きの権限が 0600 でない: \(String(describing: mode))") }
    post(key: 53, flags: []) // Escape(閉じても下書きは残る)
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    guard FileManager.default.fileExists(atPath: draftFile) else { stopInstance(dataDir: dataDir); fail("閉じたら下書きが消えた") }

    stopInstance(dataDir: dataDir)
    launchInstance(app: appPath, dataDir: dataDir)
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("再起動後にパネルが表示されない") }
    usleep(300_000)
    let restored = readPanelText(dataDir: dataDir)
    post(key: 53, flags: [])
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    stopInstance(dataDir: dataDir)
    guard restored == text else { fail("再起動後の入力欄が違う: \(String(describing: restored)) != \(text.debugDescription)") }
    print("PASS: 下書きは 0600 で保存され、閉じても残り、再起動後の入力欄へ戻った")
case "e2e-history":
    // 履歴を仕込んだ専用インスタンスで Ctrl+j/k を押し、入力欄の中身が想定どおり替わるかを確かめる
    guard AXIsProcessTrusted() else { print("Accessibility 許可が無いので実行できません"); exit(1) }
    let appPath = arg("--app", default: "")
    let owner = arg("--owner", default: "Prompt Line")
    guard !appPath.isEmpty else { print("--app が必要です"); exit(1) }
    func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }
    let dataDir = makeTempDir()
    let lines = [#"{"text":"一番古い","timestamp":1,"id":"a"}"#, #"{"text":"二番目","timestamp":2,"id":"b"}"#, #"{"text":"最新 / slash","timestamp":3,"id":"c"}"#]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: dataDir + "/history.jsonl", atomically: true, encoding: .utf8)

    launchInstance(app: appPath, dataDir: dataDir)
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("パネルが表示されない") }
    usleep(300_000)
    type("書きかけ")
    usleep(200_000)

    let ctrl: CGEventFlags = .maskControl
    let keyJ: CGKeyCode = 38, keyK: CGKeyCode = 40
    // (操作, 期待する入力欄の中身)。Ctrl+j は古い方へ、Ctrl+k は新しい方へ
    let steps: [(String, CGKeyCode, String)] = [
        ("Ctrl+j", keyJ, "最新 / slash"), ("Ctrl+j", keyJ, "二番目"), ("Ctrl+j", keyJ, "一番古い"),
        ("Ctrl+j(端)", keyJ, "一番古い"),
        ("Ctrl+k", keyK, "二番目"), ("Ctrl+k", keyK, "最新 / slash"), ("Ctrl+k(送る前へ戻る)", keyK, "書きかけ"),
        ("Ctrl+k(送っていない)", keyK, "書きかけ"),
    ]
    for (name, key, expected) in steps {
        post(key: key, flags: ctrl)
        usleep(150_000)
        let actual = readPanelText(dataDir: dataDir)
        guard actual == expected else { stopInstance(dataDir: dataDir); fail("\(name) の後の入力欄が違う: \(String(describing: actual)) != \(expected)") }
    }

    // 履歴を送っている途中で閉じても、下書きは送る前の入力のまま
    post(key: keyJ, flags: ctrl)
    usleep(150_000)
    post(key: 53, flags: [])
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    let draft = (try? String(contentsOfFile: dataDir + "/draft-swift.json", encoding: .utf8)) ?? ""
    guard draft.contains("書きかけ"), !draft.contains("最新") else { stopInstance(dataDir: dataDir); fail("下書きが送る前の入力でない: \(draft)") }
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    _ = waitUntil(timeout: 3) { panelVisible(owner: owner) }
    usleep(200_000)
    let reopened = readPanelText(dataDir: dataDir)
    post(key: 53, flags: [])
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    stopInstance(dataDir: dataDir)
    guard reopened == "書きかけ" else { fail("閉じて開き直した入力欄が違う: \(String(describing: reopened))") }
    print("PASS: Ctrl+j/k の送り・端・送る前への復帰・閉じても下書きが保たれる")
case "snap":
    // 専用インスタンスのパネルだけを撮影する(画面全体は撮らない)。例: bench snap --app X --out a.png --down 2
    let appPath = arg("--app", default: "")
    let out = arg("--out", default: "")
    let owner = arg("--owner", default: "Prompt Line")
    let downs = Int(arg("--down", default: "0")) ?? 0
    guard !appPath.isEmpty, !out.isEmpty else { print("--app と --out が必要です"); exit(1) }
    let dataDir = arg("--data-dir", default: makeTempDir())
    launchInstance(app: appPath, dataDir: dataDir)
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); print("FAIL: パネルが出ない"); exit(1) }
    usleep(300_000)
    type(arg("--text", default: ""))
    let searchQuery = arg("--search", default: "")
    if !searchQuery.isEmpty {
        post(key: 3, flags: .maskCommand)
        usleep(300_000)
        type(searchQuery)
        usleep(200_000)
    }
    for _ in 0..<downs { post(key: 38, flags: .maskControl); usleep(150_000) }
    usleep(300_000)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let id = windows.first { w in
        (w[kCGWindowOwnerName as String] as? String) == owner && ((w[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) >= 300
    }?[kCGWindowNumber as String] as? Int
    if let id { shell("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), out]) }
    post(key: 53, flags: [])
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    stopInstance(dataDir: dataDir)
    print(id == nil ? "FAIL: ウィンドウが見つからない" : "OK: \(out)")
case "e2e-search":
    // Cmd+f の検索: 絞り込み・結果の送り・Enter で確定・Esc で取消を確かめる
    guard AXIsProcessTrusted() else { print("Accessibility 許可が無いので実行できません"); exit(1) }
    let appPath = arg("--app", default: "")
    let owner = arg("--owner", default: "Prompt Line")
    guard !appPath.isEmpty else { print("--app が必要です"); exit(1) }
    func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }
    let dataDir = makeTempDir()
    let lines = [#"{"text":"a: Apple tart","timestamp":1,"id":"a"}"#, #"{"text":"b: apple pie","timestamp":2,"id":"b"}"#, #"{"text":"c: banana split","timestamp":3,"id":"c"}"#]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: dataDir + "/history.jsonl", atomically: true, encoding: .utf8)

    launchInstance(app: appPath, dataDir: dataDir)
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("パネルが表示されない") }
    usleep(300_000)
    func expectInput(_ expected: String, _ step: String) {
        usleep(200_000)
        let actual = readInputText(dataDir: dataDir)
        guard actual == expected else { stopInstance(dataDir: dataDir); fail("\(step): 入力欄が違う: \(String(describing: actual)) != \(expected.debugDescription)") }
    }
    let ctrl: CGEventFlags = .maskControl
    let keyJ: CGKeyCode = 38, keyK: CGKeyCode = 40, keyF: CGKeyCode = 3, keyReturn: CGKeyCode = 36, keyEsc: CGKeyCode = 53

    type("書きかけ")
    // 履歴を送っている途中で検索を始めても、取り消せば送る前の文章に戻り、下書きも失われない
    post(key: keyJ, flags: ctrl); expectInput("c: banana split", "履歴送りの開始")
    post(key: keyF, flags: .maskCommand)
    usleep(300_000)
    post(key: keyEsc, flags: [])                   // 検索を取り消す
    expectInput("書きかけ", "履歴送り中に始めた検索を取り消すと送る前の文章へ戻る")
    post(key: keyEsc, flags: [])                   // パネルを閉じる(下書きを保存)
    _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
    let savedDraft = (try? String(contentsOfFile: dataDir + "/draft-swift.json", encoding: .utf8)) ?? ""
    guard savedDraft.contains("書きかけ"), !savedDraft.contains("banana") else { stopInstance(dataDir: dataDir); fail("下書きが送る前の文章でない: \(savedDraft)") }
    post(key: testHotkeyKey, flags: testHotkeyFlags)
    guard waitUntil(timeout: 3, { panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("再表示できない") }
    usleep(300_000)
    expectInput("書きかけ", "再表示した入力欄")

    post(key: keyF, flags: .maskCommand)          // 検索を始める
    usleep(300_000)
    type("APPLE")                                  // 大文字小文字を区別しない: apple が 2 件
    usleep(200_000)
    post(key: keyJ, flags: ctrl); expectInput("b: apple pie", "検索 Ctrl+j(1件目=新しい方)")
    post(key: keyJ, flags: ctrl); expectInput("a: Apple tart", "検索 Ctrl+j(2件目)")
    post(key: keyJ, flags: ctrl); expectInput("a: Apple tart", "検索 Ctrl+j(端)")
    post(key: keyK, flags: ctrl); expectInput("b: apple pie", "検索 Ctrl+k")
    post(key: keyK, flags: ctrl); expectInput("書きかけ", "検索 Ctrl+k(送る前へ戻る)")

    post(key: keyJ, flags: ctrl); expectInput("b: apple pie", "確定の準備")
    post(key: keyReturn, flags: [])                // Enter: 選んだ履歴を入力として残す
    expectInput("b: apple pie", "Enter で確定")
    type("!")                                      // 検索欄ではなく入力欄へ戻っている
    expectInput("b: apple pie!", "確定後の入力欄へフォーカスが戻る")

    // ここから Caps Lock 中(追加の修飾フラグが立っていても、ショートカットが効く)
    let caps: CGEventFlags = .maskAlphaShift
    post(key: keyF, flags: [.maskCommand, .maskAlphaShift])
    usleep(300_000)
    type("banana")
    usleep(200_000)
    post(key: keyJ, flags: [.maskControl, .maskAlphaShift]); expectInput("c: banana split", "取消の準備")
    post(key: keyEsc, flags: caps)                 // Esc: 送る前の文章へ戻して検索を終える
    expectInput("b: apple pie!", "Esc で取消")

    post(key: keyF, flags: .maskCommand)
    usleep(300_000)
    type("zzz")
    usleep(200_000)
    post(key: keyJ, flags: ctrl); expectInput("b: apple pie!", "一致なしでは何も変わらない")
    post(key: keyEsc, flags: [])
    expectInput("b: apple pie!", "一致なしからの取消")
    post(key: keyEsc, flags: [])                   // 検索を終えていれば、次の Esc でパネルが閉じる
    guard waitUntil(timeout: 3, { !panelVisible(owner: owner) }) != nil else { stopInstance(dataDir: dataDir); fail("検索を終えた後の Esc でパネルが閉じない") }
    stopInstance(dataDir: dataDir)
    print("PASS: 検索の絞り込み・送り・Enter 確定・Esc 取消・一致なし")
case "show":
    guard AXIsProcessTrusted() else { print("この端末に Accessibility 許可が無いのでキーを送れません"); exit(1) }
    let owner = arg("--owner", default: "Prompt Line")
    let runs = Int(arg("--runs", default: "10")) ?? 10
    guard !panelVisible(owner: owner) else { print("すでにパネルが表示されています。閉じてから流してください"); exit(1) }
    let hotkeyFlags = flags(from: arg("--mods", default: "cmd+shift"))
    let hotkeyCode = UInt16(arg("--key", default: "49")).map { CGKeyCode($0) } ?? 49
    var times: [Double] = []
    for i in 1...runs {
        let t0 = post(key: hotkeyCode, flags: hotkeyFlags)
        guard let _ = waitUntil(timeout: 3, { panelVisible(owner: owner) }) else {
            print("run \(i): 3秒以内に表示されませんでした"); continue
        }
        let ms = elapsedMs(since: t0)
        times.append(ms)
        print(String(format: "run %d: %.0f ms", i, ms))
        usleep(300_000)
        post(key: 53, flags: []) // Escape
        _ = waitUntil(timeout: 3) { !panelVisible(owner: owner) }
        sleep(1)
    }
    if !times.isEmpty { print("show: " + summarize(times)) }
case "rss":
    let match = arg("--match", default: "/Applications/Prompt Line.app")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "rss=,command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var total = 0, count = 0
    for line in out.split(separator: "\n") {
        // 先頭が RSS、その後ろがコマンド行。コマンドが match で始まるものだけ数える(シェルの引数に現れる文字列は除く)
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let kb = Int(parts[0]), parts[1].hasPrefix(match) else { continue }
        total += kb; count += 1
    }
    print(String(format: "rss: %d processes, %.0f MB", count, Double(total) / 1024))
default:
    print("usage: bench show [--runs N] [--owner NAME] | bench rss [--match STR]")
    exit(1)
}
