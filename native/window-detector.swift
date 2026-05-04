import Cocoa
import ApplicationServices
import Foundation

class WindowDetector {
    static func getActiveWindowBounds() -> [String: Any] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return ["error": "No active application found"]
        }
        
        // Get the process ID of the frontmost application
        let pid = frontApp.processIdentifier
        
        // Get window list for the frontmost application
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ["error": "Failed to get window list"]
        }
        
        for window in windowList {
            if let windowPID = window[kCGWindowOwnerPID as String] as? Int32,
               let windowLayer = window[kCGWindowLayer as String] as? Int,
               windowPID == pid && windowLayer == 0 {
                
                if let bounds = window[kCGWindowBounds as String] as? [String: Any],
                   let x = bounds["X"] as? NSNumber,
                   let y = bounds["Y"] as? NSNumber,
                   let width = bounds["Width"] as? NSNumber,
                   let height = bounds["Height"] as? NSNumber {
                    
                    var result: [String: Any] = [
                        "x": x,
                        "y": y,
                        "width": width,
                        "height": height,
                        "appName": frontApp.localizedName ?? "Unknown"
                    ]
                    
                    if let bundleId = frontApp.bundleIdentifier {
                        result["bundleId"] = bundleId
                    } else {
                        result["bundleId"] = NSNull()
                    }
                    
                    return result
                }
            }
        }
        
        return ["error": "No active window found"]
    }
    
    static func getCurrentApp() -> [String: Any] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return ["error": "No active application found"]
        }

        var result: [String: Any] = [
            "name": frontApp.localizedName ?? "Unknown"
        ]

        if let bundleId = frontApp.bundleIdentifier {
            result["bundleId"] = bundleId
        } else {
            result["bundleId"] = NSNull()
        }

        return result
    }

    // Find the topmost on-screen window that belongs to an app other than Prompt Line.
    // Used as a fallback when Prompt Line is frontmost (e.g. just after launch) and
    // we have no stored previous-app value to paste to.
    static func getPreviousApp() -> [String: Any] {
        // Exclude by both process name and bundle ID to handle production and dev builds.
        // Production: name="Prompt Line", bundleId="com.electron.prompt-line"
        // Development: name="Electron",   bundleId="com.github.Electron"
        let excludedNames: Set<String> = ["Prompt Line", "Electron"]
        let excludedBundleIds: Set<String> = ["com.electron.prompt-line", "com.github.Electron"]

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return ["error": "Failed to get window list"]
        }

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                if let bundleId = runningApp.bundleIdentifier {
                    if excludedBundleIds.contains(bundleId) { continue }
                } else if excludedNames.contains(ownerName) {
                    continue
                }
                var result: [String: Any] = [
                    "name": runningApp.localizedName ?? ownerName
                ]
                if let bundleId = runningApp.bundleIdentifier {
                    result["bundleId"] = bundleId
                } else {
                    result["bundleId"] = NSNull()
                }
                return result
            }
        }

        return ["error": "No previous application found"]
    }
}

func main() {
    let arguments = CommandLine.arguments
    
    guard arguments.count >= 2 else {
        fputs("Usage: \(arguments[0]) <command>\n", stderr)
        fputs("Commands: window-bounds, current-app\n", stderr)
        exit(1)
    }
    
    let command = arguments[1]
    let result: [String: Any]
    
    switch command {
    case "window-bounds":
        result = WindowDetector.getActiveWindowBounds()

    case "current-app":
        result = WindowDetector.getCurrentApp()

    case "previous-app":
        result = WindowDetector.getPreviousApp()

    default:
        fputs("Unknown command: \(command)\n", stderr)
        exit(1)
    }
    
    // Convert result to JSON and output
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: result, options: [])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        fputs("JSON serialization error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    
    exit(0)
}

main()