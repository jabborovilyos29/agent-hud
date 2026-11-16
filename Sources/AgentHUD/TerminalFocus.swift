import AgentHUDCore
import AppKit
import Foundation

/// Кнопка «Открыть»: поднять приложение или вкладку терминала, где идёт сессия.
enum TerminalFocus {
    static func focus(_ session: AgentSession) {
        let host = session.host
        if host.isDesktopApp {
            if let url = deepLink(session) {
                NSWorkspace.shared.open(url)
            } else if let id = host.appBundleId {
                activate(id)
            }
            return
        }
        focus(host)
    }

    /// Ссылка прямо в сессию десктопного приложения (форматы взяты из самих приложений).
    static func deepLink(_ session: AgentSession) -> URL? {
        switch session.host.appBundleId {
        case HostInfo.claudeDesktop:
            guard let id = session.host.hostSessionId else { return nil }
            var c = URLComponents(string: "claude://code/needs-input")!
            c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "desktop_action")]
            return c.url
        case HostInfo.codexDesktop:
            let id = session.sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.sessionId
            return URL(string: "codex://threads/\(id)")
        default:
            return nil
        }
    }

    static func focus(_ host: HostInfo) {
        if let pane = host.herdrPaneId {
            focusHerdr(pane: pane, socket: host.herdrSocket)
            // Вкладка Terminal, в которой открыт клиент herdr.
            if !runAppleScript(terminalScript(match: "processes of t contains \"herdr\"")) { activate("com.apple.Terminal") }
            return
        }
        if let tty = host.tty {
            if host.termProgram == "iTerm.app", runAppleScript(iTermScript(tty: tty)) { return }
            if runAppleScript(terminalScript(match: "tty of t is \"\(tty)\"")) { return }
        }
        switch host.termProgram {
        case "iTerm.app": activate("com.googlecode.iterm2")
        default: activate("com.apple.Terminal")
        }
    }

    static func activate(_ bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Найти вкладку Terminal.app по условию, выбрать её и поднять окно.
    static func terminalScript(match condition: String) -> String {
        """
        if application "Terminal" is not running then return false
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if \(condition) then
                        set selected of t to true
                        set index of w to 1
                        if miniaturized of w then set miniaturized of w to false
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func iTermScript(tty: String) -> String {
        """
        if application "iTerm2" is not running then return false
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    @discardableResult
    static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error { NSLog("AgentHUD AppleScript: \(error)") }
        return error == nil && result.booleanValue
    }

    static func focusHerdr(pane: String, socket: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["agent", "focus", pane]
        var env = ProcessInfo.processInfo.environment
        if let socket { env["HERDR_SOCKET_PATH"] = socket }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // Не ждём дольше секунды, чтобы не подвесить интерфейс.
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
    }
}
