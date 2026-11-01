import AppKit
import Carbon.HIToolbox

enum Paster {
    /// パネルが key を手放してアプリ側へ戻るまでの待ち時間は実機で調整する。
    static let keyReturnDelay: TimeInterval = 0.03
    /// 貼り付け先が前面になるのを待つ上限。超えたら送らない(本文はクリップボードと履歴に残る)
    static let frontmostTimeout: TimeInterval = 0.3

    /// 貼り付け要求の世代。新しい要求が始まったら、待っている古い要求は送らずに終わる
    private static var generation = 0

    /// 本文をクリップボードへ置き、貼り付け先が前面であることを確かめてから Cmd+V を送る。
    /// 待っている間に貼り付け先が終了した・別アプリが前面になった・パネルが再表示された場合は、誤送信を避けて送らない。
    static func paste(_ text: String, into target: NSRunningApplication, after panel: NSPanel) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        panel.orderOut(nil)

        if !target.isActive { target.activate() }
        generation += 1
        sendWhenFrontmost(target, panel: panel, generation: generation, delay: keyReturnDelay, deadline: .now() + frontmostTimeout)
    }

    private static func sendWhenFrontmost(_ target: NSRunningApplication, panel: NSPanel, generation requested: Int, delay: TimeInterval, deadline: DispatchTime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 世代が替わった・パネルが再表示された・貼り付け先が終了した・期限を過ぎた、のどれかなら送らない
            guard generation == requested, !panel.isVisible, !target.isTerminated, DispatchTime.now() < deadline else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                sendCommandV()
            } else {
                sendWhenFrontmost(target, panel: panel, generation: requested, delay: 0.02, deadline: deadline)
            }
        }
    }

    static func sendCommandV() {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
            if down { usleep(10_000) }
        }
    }
}
