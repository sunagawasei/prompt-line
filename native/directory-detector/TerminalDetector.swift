import Cocoa
import Foundation

// MARK: - Terminal Detection

extension DirectoryDetector {

    // MARK: - Terminal.app tty detection

    static func getTerminalTty() -> String? {
        let script = """
        tell application "Terminal"
            set W to the front window
            set T to selected tab of W
            return tty of T
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        guard let result = appleScript?.executeAndReturnError(&error) else {
            return nil
        }

        return result.stringValue
    }

    // MARK: - iTerm2 tty detection

    static func getiTerm2Tty() -> String? {
        let script = """
        tell application "iTerm2"
            tell current session of current tab of current window
                return tty
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        guard let result = appleScript?.executeAndReturnError(&error) else {
            return nil
        }

        return result.stringValue
    }

    // MARK: - cmux directory detection

    /// Check if bundle ID is cmux
    static func isCmux(_ bundleId: String) -> Bool {
        return bundleId == "com.cmuxterm.app"
    }

    /// Get working directory from cmux's focused terminal via AppleScript.
    /// Why AppleScript instead of process-tree: cmux embeds Ghostty internally, but
    /// the parent app's bundle ID is what NSWorkspace.frontmostApplication returns,
    /// so process-tree detection (used for Ghostty/Warp/WezTerm) wouldn't match.
    /// cmux exposes a "working directory" property on its focused terminal
    /// (see Contents/Resources/cmux.sdef in the app bundle).
    static func getCmuxWorkingDirectory() -> String? {
        // `focused terminal` can momentarily be nil (e.g. right after a pane split or
        // when no pane has keyboard focus). Fall back to the tab's first terminal so we
        // still return a directory instead of failing the whole detection.
        let script = """
        tell application "cmux"
            tell front window
                tell selected tab
                    try
                        return working directory of focused terminal
                    on error
                        return working directory of (first terminal)
                    end try
                end tell
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        guard let result = appleScript?.executeAndReturnError(&error),
              let value = result.stringValue,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - Native Terminal Detection (Ghostty, Warp, WezTerm)

    /// Check if bundle ID is Ghostty
    static func isGhostty(_ bundleId: String) -> Bool {
        return bundleId == "com.mitchellh.ghostty"
    }

    /// Check if bundle ID is Warp
    static func isWarp(_ bundleId: String) -> Bool {
        return bundleId == "dev.warp.Warp-Stable"
    }

    /// Check if bundle ID is WezTerm
    static func isWezTerm(_ bundleId: String) -> Bool {
        return bundleId == "com.github.wez.wezterm"
    }

    /// Check if bundle ID is a native terminal (Ghostty, Warp, WezTerm)
    /// These terminals use process tree detection for CWD
    static func isNativeTerminal(_ bundleId: String) -> Bool {
        return isGhostty(bundleId) || isWarp(bundleId) || isWezTerm(bundleId)
    }

    /// Get CWD from native terminal using optimized process tree detection
    /// Works for Ghostty, Warp, WezTerm, and other native terminals
    /// Uses the same fast approach as Electron IDE detection
    static func getNativeTerminalDirectory(appPid: pid_t) -> (directory: String?, shellPid: pid_t?) {
        // One `ps` call gathers pid/ppid/tty/comm for every process. We avoid
        // `pgrep -f` because macOS pgrep silently drops long-running processes
        // whose KERN_PROCARGS2 has become unreadable — the focused login shell
        // of an old Ghostty tab is exactly the one that gets dropped.
        let snapshot = snapshotProcessesWithTty()
        if snapshot.isEmpty {
            return (nil, nil)
        }

        // Reuse the snapshot for parent lookups so we don't fork another `ps`.
        var parentMap: [pid_t: pid_t] = [:]
        parentMap.reserveCapacity(snapshot.count)
        for entry in snapshot {
            parentMap[entry.pid] = entry.ppid
        }

        // Pick the shell whose tty was most recently active. A pty's mtime
        // advances on read/write traffic, so it tracks the tab/window the user
        // just interacted with. Ghostty's AX hierarchy only exposes the focused
        // window's title — there is no direct pty mapping — so tty mtime is
        // what lets us resolve focus across multiple terminal windows/tabs.
        struct ShellCandidate {
            let pid: pid_t
            let cwd: String
            let ttyMtime: TimeInterval
        }

        var candidates: [ShellCandidate] = []
        for entry in snapshot where isShellCommand(entry.comm) && !entry.tty.isEmpty {
            guard isDescendantOf(entry.pid, ancestorPid: appPid, parentMap: parentMap, maxDepth: 10) else { continue }
            guard let cwd = getCwdFromPid(entry.pid) else { continue }
            let mtime = mtimeForTty(entry.tty) ?? 0
            candidates.append(ShellCandidate(pid: entry.pid, cwd: cwd, ttyMtime: mtime))
        }

        if candidates.isEmpty {
            return (nil, nil)
        }

        // Sort shells with a known tty mtime first (newest first); shells
        // without a resolvable tty fall back to pid order (newest first).
        candidates.sort { lhs, rhs in
            if lhs.ttyMtime > 0 && rhs.ttyMtime > 0 {
                return lhs.ttyMtime > rhs.ttyMtime
            }
            if lhs.ttyMtime > 0 { return true }
            if rhs.ttyMtime > 0 { return false }
            return lhs.pid > rhs.pid
        }

        let focused = candidates[0]
        return (focused.cwd, focused.pid)
    }

    private struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let tty: String
        let comm: String
    }

    /// Capture pid/ppid/tty/comm for every process in a single `ps` invocation.
    private static func snapshotProcessesWithTty() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Drain before waiting — `ps -ax` output exceeds the 64KB pipe
            // buffer on busy systems, and waiting first would deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }

            var entries: [ProcessEntry] = []
            entries.reserveCapacity(256)

            for rawLine in output.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                if parts.count < 4 { continue }
                guard let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else { continue }
                let tty = parts[2] == "??" ? "" : String(parts[2])
                // `ps` pads each column to a fixed width, so the comm slice
                // can carry a leading space (e.g. " -zsh"). Trim before use —
                // otherwise isShellCommand misses WezTerm's "-zsh" entries.
                let comm = parts[3].trimmingCharacters(in: .whitespaces)
                entries.append(ProcessEntry(pid: pid, ppid: ppid, tty: tty, comm: comm))
            }

            return entries
        } catch {
            return []
        }
    }

    private static func mtimeForTty(_ tty: String) -> TimeInterval? {
        let path = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate.timeIntervalSince1970
    }

    /// Get CWD from Ghostty terminal.
    /// Ghostty exposes the focused pane's working directory via the AXWindow's
    /// `AXDocument` attribute (the proxy-icon URL). This updates instantly on
    /// pane/tab focus changes, while tty mtime can lag by seconds because
    /// background panes keep redrawing their prompts.
    /// Falls back to the generic process-tree detector if AX is unavailable.
    static func getGhosttyDirectory(appPid: pid_t) -> (directory: String?, shellPid: pid_t?, usedAx: Bool) {
        if let path = getGhosttyDirectoryViaAx(appPid: appPid) {
            // shellPid is only emitted as metadata; nothing in the renderer
            // depends on it. Skip the ps walk entirely when AX gives us a
            // direct answer — that keeps detection well under 50ms.
            return (path, nil, true)
        }
        let fallback = getNativeTerminalDirectory(appPid: appPid)
        return (fallback.directory, fallback.shellPid, false)
    }

    /// Read the focused pane's CWD from AXWindow.AXDocument. Returns nil when
    /// the attribute is missing or doesn't decode as a `file://` URL.
    private static func getGhosttyDirectoryViaAx(appPid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(appPid)

        var focusedWinRef: CFTypeRef?
        let winResult = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWinRef)
        guard winResult == .success, let focusedWindow = focusedWinRef else { return nil }
        let win = focusedWindow as! AXUIElement

        var docRef: CFTypeRef?
        let docResult = AXUIElementCopyAttributeValue(win, "AXDocument" as CFString, &docRef)
        guard docResult == .success else { return nil }

        // AXDocument is documented as a String containing a file URL on macOS,
        // but defensively accept NSURL too in case Ghostty switches encoding.
        let urlString: String?
        if let s = docRef as? String {
            urlString = s
        } else if let url = docRef as? NSURL {
            urlString = url.absoluteString
        } else {
            urlString = nil
        }

        guard let str = urlString,
              let url = URL(string: str),
              url.isFileURL else {
            return nil
        }

        var path = url.path
        // Other detectors return paths without a trailing slash; normalise here.
        if path.hasSuffix("/") && path != "/" {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }

    /// Get CWD from Warp terminal (wrapper for getNativeTerminalDirectory)
    static func getWarpDirectory(appPid: pid_t) -> (directory: String?, shellPid: pid_t?) {
        return getNativeTerminalDirectory(appPid: appPid)
    }

    /// Get CWD from WezTerm terminal.
    /// Prefers `wezterm cli` because tty mtime is unreliable on WezTerm —
    /// background panes/tabs keep redrawing prompts (starship, themes), so
    /// the focused pane often has neither the newest mtime nor a clear lead.
    /// Falls back to the generic process-tree detector if the CLI fails.
    static func getWezTermDirectory(appPid: pid_t) -> (directory: String?, shellPid: pid_t?, usedCli: Bool, tty: String?) {
        if let result = getWezTermDirectoryViaCli() {
            return (result.directory, result.shellPid, true, result.tty)
        }
        let fallback = getNativeTerminalDirectory(appPid: appPid)
        // Process-tree tty is chosen by mtime and isn't guaranteed to match the
        // focused pane, so never surface it — only the CLI path's tty is trustworthy.
        return (fallback.directory, fallback.shellPid, false, nil)
    }

    /// Ask the running WezTerm GUI which pane is focused via `wezterm cli`.
    /// Returns nil if the CLI is unavailable, the daemon is not reachable,
    /// or the JSON shape is unexpected — callers should fall back.
    ///
    /// Resolving a socket doesn't guarantee `wezterm cli` avoids spawning a
    /// mux server: if connecting to that socket still fails, `wezterm cli`
    /// can try to daemonize one anyway, and a failing environment hits this
    /// on every detection call — deadline recovery in `runWezTermCli` bounds
    /// our own wait, not what the daemonized process does afterward.
    private static func getWezTermDirectoryViaCli() -> (directory: String, shellPid: pid_t?, tty: String?)? {
        // Single monotonic deadline shared by socket resolution and both CLI
        // calls: it bounds every blocking wait (poll for output, process
        // exit) below, but synchronous work in between — JSON parsing,
        // spawning `Process`, filesystem/libproc calls — isn't itself cut
        // short by it, so overrun is small in practice but not a hard cap.
        // Monotonic (not wall-clock) so a clock step doesn't shrink or
        // stretch the 1s budget.
        let deadline = DispatchTime.now() + 1.0

        // If we can't identify the GUI's socket, don't run the CLI at all:
        // launching `Process` without WEZTERM_UNIX_SOCKET inherits the
        // parent's environment, so a stray inherited socket would silently
        // target the wrong GUI.
        guard let socketPath = wezTermGuiSocketPath(deadline: deadline) else {
            return nil
        }

        guard let focusedPaneId = runWezTermCli(
            args: ["cli", "list-clients", "--format", "json"],
            deadline: deadline,
            socketPath: socketPath
        ).flatMap({ parseFirstFocusedPaneId(from: $0) }) else {
            return nil
        }

        guard let paneListData = runWezTermCli(
                args: ["cli", "list", "--format", "json"],
                deadline: deadline,
                socketPath: socketPath
              ),
              let panes = (try? JSONSerialization.jsonObject(with: paneListData)) as? [[String: Any]],
              let pane = panes.first(where: { ($0["pane_id"] as? Int) == focusedPaneId }),
              let cwdString = pane["cwd"] as? String,
              let directory = pathFromCwdString(cwdString) else {
            return nil
        }

        // shellPid is left nil on this path: nothing reads it (TS resolves the
        // focused pid itself from `tty`), and getShellPidFromTty's unbounded
        // `ps` wait would reintroduce the deadline-less hang this function
        // exists to avoid.
        let ttyName = pane["tty_name"] as? String
        return (directory, nil, ttyName)
    }

    /// Resolve the running WezTerm GUI's unix socket. Identity starts from
    /// the process, not the filesystem: `gui-sock-*` files accumulate across
    /// restarts (stale files from old runs are common), so counting files
    /// can't establish uniqueness — counting live `wezterm-gui` processes can.
    /// Doesn't read `~/.local/share/wezterm/pid` — that file can name a
    /// wezterm-mux-server pid instead of the GUI's, pointing at a socket
    /// that doesn't exist.
    static func wezTermGuiSocketPath(deadline: DispatchTime) -> String? {
        guard let guiPids = liveWezTermGuiPids(deadline: deadline),
              guiPids.count == 1,
              let guiPid = guiPids.first else {
            return nil
        }

        var searchDirs: [String] = []
        if let xdgRuntimeDir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdgRuntimeDir.isEmpty {
            searchDirs.append("\(xdgRuntimeDir)/wezterm")
        }
        // Read HOME from the environment rather than NSHomeDirectory(): the
        // latter can keep reporting the login directory after HOME has been
        // overridden, which is what wezterm itself honors when placing sockets.
        let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let fallbackDir = "\(homeDir)/.local/share/wezterm"
        if !searchDirs.contains(fallbackDir) {
            searchDirs.append(fallbackDir)
        }

        // Only the one live GUI's own socket file counts as a match. Both
        // dirs can hold a same-named file (e.g. a stale one left behind by
        // an earlier XDG_RUNTIME_DIR), so "first one found" wouldn't be a
        // unique answer — require exactly one to actually exist.
        let fileManager = FileManager.default
        var matches: [String] = []
        for dir in searchDirs {
            guard DispatchTime.now() < deadline else { return nil }
            let candidate = "\(dir)/gui-sock-\(guiPid)"
            if fileManager.fileExists(atPath: candidate) {
                matches.append(candidate)
            }
        }

        return matches.count == 1 ? matches[0] : nil
    }

    /// Full executable path for a live pid via libproc, or nil if the pid is
    /// gone or unreadable.
    private static func executablePath(forPid pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN) isn't bridgeable to Swift; inline it.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Enumerate all live wezterm-gui pids via libproc (no subprocess).
    /// Returns nil — distinct from an empty result — if the pid list might
    /// be truncated or the deadline ran out before that could be ruled out;
    /// a possibly-truncated list must never be treated as "all of them".
    private static func liveWezTermGuiPids(deadline: DispatchTime) -> [pid_t]? {
        guard DispatchTime.now() < deadline else { return nil }
        let pidSize = MemoryLayout<pid_t>.size

        let sizeQuery = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizeQuery > 0 else { return nil }
        // The size query is already an overestimate, but processes can start
        // between this call and the fetch below, so pad further still.
        var bufferByteCount = Int(sizeQuery) + 256 * pidSize

        var rawPids: [pid_t]?
        for _ in 0..<5 {
            guard DispatchTime.now() < deadline else { return nil }

            var buffer = [pid_t](repeating: 0, count: bufferByteCount / pidSize)
            let filled = buffer.withUnsafeMutableBytes { ptr in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, Int32(ptr.count))
            }
            guard filled > 0 else { return nil }

            if Int(filled) >= bufferByteCount {
                // The buffer came back exactly full, so it may have been
                // truncated — grow and retry rather than trust a partial list.
                bufferByteCount *= 2
                continue
            }

            rawPids = Array(buffer.prefix(Int(filled) / pidSize))
            break
        }
        guard let pids = rawPids else { return nil }

        var guiPids: [pid_t] = []
        for pid in pids where pid != 0 {
            guard DispatchTime.now() < deadline else { return nil }
            guard let path = executablePath(forPid: pid),
                  (path as NSString).lastPathComponent == "wezterm-gui" else { continue }
            guiPids.append(pid)
        }
        return guiPids
    }

    /// Locate the WezTerm CLI. Prefer the binary the user already has on
    /// PATH; fall back to the bundled binary so we still work when PATH
    /// isn't inherited (e.g. Electron launched from Finder).
    private static func wezTermCliPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        ]
        let fileManager = FileManager.default
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Run a `wezterm cli` subcommand. The blocking waits — polling for
    /// output and waiting for the child to exit, including SIGTERM/SIGKILL
    /// recovery on timeout — are all bounded by `deadline` and leave no
    /// reader thread behind (reading happens inline via `poll`, not on a
    /// second thread). `process.run()` and parsing the result aren't
    /// themselves cut short by the deadline. Output is capped at
    /// `wezTermCliMaxOutputBytes`; a child stuck past the deadline is
    /// SIGKILL'd but not waited on further, so it isn't guaranteed to be
    /// reaped before this function returns.
    private static func runWezTermCli(args: [String], deadline: DispatchTime, socketPath: String?) -> Data? {
        guard DispatchTime.now() < deadline else { return nil }
        guard let cliPath = wezTermCliPath() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        if let socketPath = socketPath {
            // Copy the inherited environment rather than replacing it —
            // replacing drops PATH and everything else the child needs.
            var env = ProcessInfo.processInfo.environment
            env["WEZTERM_UNIX_SOCKET"] = socketPath
            process.environment = env
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        let readHandle = pipe.fileHandleForReading
        let fd = readHandle.fileDescriptor
        defer { try? readHandle.close() }

        let currentFlags = fcntl(fd, F_GETFL, 0)
        guard currentFlags != -1, fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
            // Fail closed: if we can't confirm O_NONBLOCK took effect, don't
            // read at all — a blocking read here could hang past `deadline`
            // undetected.
            terminateWezTermCli(process, exitSemaphore: exitSemaphore, deadline: deadline)
            return nil
        }

        let collected = readWezTermCliOutput(fd: fd, deadline: deadline)
        guard let collected else {
            terminateWezTermCli(process, exitSemaphore: exitSemaphore, deadline: deadline)
            return nil
        }

        if exitSemaphore.wait(timeout: deadline) == .timedOut {
            terminateWezTermCli(process, exitSemaphore: exitSemaphore, deadline: deadline)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return collected
    }

    /// Upper bound on a single `wezterm cli` invocation's stdout: keeps this
    /// call's memory bounded regardless of what the child writes.
    private static let wezTermCliMaxOutputBytes = 4 * 1024 * 1024

    /// Drain `fd` (already `O_NONBLOCK`) via `poll`, bounded by `deadline`.
    /// Returns nil on timeout, a read error, or exceeding
    /// `wezTermCliMaxOutputBytes` — all cases the caller should treat as "no
    /// usable output", not partial data.
    private static func readWezTermCliOutput(fd: Int32, deadline: DispatchTime) -> Data? {
        var collected = Data()
        while true {
            let timeoutMs = millisecondsUntilDeadline(deadline)
            guard timeoutMs > 0 else { return nil }

            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&fds, 1, timeoutMs)
            if pollResult < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard pollResult > 0 else { return nil } // no data before deadline

            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let bytesRead = chunk.withUnsafeMutableBytes { buffer in
                read(fd, buffer.baseAddress, buffer.count)
            }
            if bytesRead > 0 {
                collected.append(contentsOf: chunk[0..<bytesRead])
                guard collected.count <= wezTermCliMaxOutputBytes else { return nil }
            } else if bytesRead == 0 {
                return collected // EOF
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    /// Escalate SIGTERM → SIGKILL for a still-running child, each wait bounded
    /// by `deadline`. Fire-and-forget past the deadline: doesn't block this
    /// call any further to confirm the kill was fully reaped.
    private static func terminateWezTermCli(_ process: Process, exitSemaphore: DispatchSemaphore, deadline: DispatchTime) {
        guard process.isRunning else { return }
        process.terminate()
        if exitSemaphore.wait(timeout: deadline) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exitSemaphore.wait(timeout: deadline)
        }
    }

    /// Milliseconds remaining until `deadline`, clamped to `[0, Int32.max]`
    /// for use as a `poll()` timeout.
    private static func millisecondsUntilDeadline(_ deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now()
        guard deadline > now else { return 0 }
        let nanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        return Int32(min(nanoseconds / 1_000_000, UInt64(Int32.max)))
    }

    private static func parseFirstFocusedPaneId(from data: Data) -> Int? {
        guard let clients = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        // WezTerm reports one client per connected GUI; the GUI process is
        // what we care about. Take the first entry that has a focused pane.
        for client in clients {
            if let paneId = client["focused_pane_id"] as? Int {
                return paneId
            }
        }
        return nil
    }

    /// Convert a `cwd` string from `wezterm cli list` into a filesystem path.
    /// WezTerm reports either a `file://` URL (with percent-encoding) or, on
    /// older builds, a bare path.
    private static func pathFromCwdString(_ cwd: String) -> String? {
        if cwd.hasPrefix("file://") {
            if let url = URL(string: cwd), url.isFileURL {
                return url.path
            }
            return nil
        }
        return cwd.isEmpty ? nil : cwd
    }
}
