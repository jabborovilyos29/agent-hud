import AgentHUDCore
import AppKit
import SwiftUI

/// Демонстрационные сессии: посмотреть HUD без настоящих агентов.
@MainActor
enum Demo {
    static func events(now: Date = Date()) -> [AgentEvent] {
        func ev(_ sid: String, _ cwd: String, _ dt: TimeInterval, _ body: AgentEvent.Body, tty: String = "/dev/ttys004") -> AgentEvent {
            // demo-c и demo-d — Codex, чтобы в превью были оба агента.
            let kind: AgentKind = (sid == "demo-c" || sid == "demo-d") ? .codex : .claude
            return AgentEvent(kind: kind, sessionId: sid, cwd: cwd, host: HostInfo(termProgram: "Apple_Terminal", tty: tty),
                       time: now.addingTimeInterval(dt), body: body)
        }
        let a = "demo-a", b = "demo-b", c = "demo-c", d = "demo-d"
        let pa = "/Users/dev/club-bot", pb = "/Users/dev/agent-management", pc = "/Users/dev/landing", pd = "/Users/dev/youtube"
        let deadline = now.addingTimeInterval(540)
        let qInput: JSONValue = ["questions": [[
            "question": "Какую базу данных взять для очереди задач?",
            "header": "База",
            "multiSelect": false,
            "options": [
                ["label": "SQLite", "description": "Один файл, без сервера"],
                ["label": "Postgres", "description": "Уже есть на сервере"],
                ["label": "Redis", "description": "Быстро, но ещё один сервис"],
            ],
        ]]]
        return [
            ev(a, pa, -1500, .sessionStarted(source: "startup", model: "claude-opus-5-5")),
            ev(a, pa, -1490, .promptSubmitted("Почини рассылку в боте клуба и прогони тесты")),
            ev(a, pa, -1400, .toolStarted(toolName: "Read", input: ["file_path": .string("\(pa)/src/mailer.ts")], toolUseId: "a1")),
            ev(a, pa, -1399, .toolFinished(toolName: "Read", input: ["file_path": .string("\(pa)/src/mailer.ts")], toolUseId: "a1", durationMs: 40, failed: false)),
            ev(a, pa, -1300, .toolStarted(toolName: "Edit", input: ["file_path": .string("\(pa)/src/mailer.ts")], toolUseId: "a2")),
            ev(a, pa, -1298, .toolFinished(toolName: "Edit", input: ["file_path": .string("\(pa)/src/mailer.ts")], toolUseId: "a2", durationMs: 120, failed: false)),
            ev(a, pa, -60, .toolStarted(toolName: "Bash", input: ["command": "npm test -- mailer"], toolUseId: "a3")),
            ev(a, pa, -60, .permissionRequested(requestId: "demo-perm", toolName: "Bash",
                                                input: ["command": "rm -rf dist && npm run build && npm test -- mailer",
                                                        "description": "Пересобрать проект и прогнать тесты рассылки"],
                                                deadline: deadline)),

            ev(b, pb, -900, .sessionStarted(source: "startup", model: "claude-sonnet-5-5"), tty: "/dev/ttys005"),
            ev(b, pb, -890, .promptSubmitted("Напиши спецификацию AgentHUD"), tty: "/dev/ttys005"),
            ev(b, pb, -800, .toolStarted(toolName: "WebFetch", input: ["url": "https://code.claude.com/docs/en/hooks"], toolUseId: "b1"), tty: "/dev/ttys005"),
            ev(b, pb, -795, .toolFinished(toolName: "WebFetch", input: ["url": "https://code.claude.com/docs/en/hooks"], toolUseId: "b1", durationMs: 4800, failed: false), tty: "/dev/ttys005"),
            ev(b, pb, -20, .toolStarted(toolName: "AskUserQuestion", input: qInput, toolUseId: "b2"), tty: "/dev/ttys005"),
            ev(b, pb, -20, .questionAsked(requestId: "demo-q", questions: ClaudeCodeAdapter.parseQuestions(qInput), rawInput: qInput, deadline: deadline), tty: "/dev/ttys005"),

            ev(c, pc, -300, .sessionStarted(source: "startup", model: "claude-opus-5-5"), tty: "/dev/ttys006"),
            ev(c, pc, -290, .promptSubmitted("Сверстай новый первый экран лендинга"), tty: "/dev/ttys006"),
            ev(c, pc, -100, .toolStarted(toolName: "Write", input: ["file_path": .string("\(pc)/app/page.tsx")], toolUseId: "c1"), tty: "/dev/ttys006"),
            ev(c, pc, -99, .toolFinished(toolName: "Write", input: ["file_path": .string("\(pc)/app/page.tsx")], toolUseId: "c1", durationMs: 90, failed: false), tty: "/dev/ttys006"),
            ev(c, pc, -5, .toolStarted(toolName: "Bash", input: ["command": "npm run lint"], toolUseId: "c2"), tty: "/dev/ttys006"),

            ev(d, pd, -2000, .sessionStarted(source: "startup", model: "claude-opus-5-5"), tty: "/dev/ttys007"),
            ev(d, pd, -1990, .promptSubmitted("Сделай тайм-коды для нового видео"), tty: "/dev/ttys007"),
            ev(d, pd, -1900, .toolStarted(toolName: "Read", input: ["file_path": .string("\(pd)/transcript.txt")], toolUseId: "d1"), tty: "/dev/ttys007"),
            ev(d, pd, -1899, .toolFinished(toolName: "Read", input: ["file_path": .string("\(pd)/transcript.txt")], toolUseId: "d1", durationMs: 30, failed: false), tty: "/dev/ttys007"),
            ev(d, pd, -1800, .stopped(lastMessage: "Готово: 14 глав, проверил по правилам YouTube — первая с 00:00, все длиннее 10 секунд. Файл chapters.txt лежит в папке видео.", failed: false), tty: "/dev/ttys007"),
        ]
    }

    static func populate(_ model: AppModel) {
        model.inject(events())
    }
}

/// Рендер персонажей и окошек в PNG — для проверки внешнего вида без экрана.
@MainActor
enum Previews {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = Settings()
        let model = AppModel(settings: settings)
        model.inject(Demo.events())

        let states: [AgentState] = [.working, .waitingPermission, .waitingAnswer, .expired, .done, .error, .idle]
        let seeds: [UInt64] = (0..<6).map { stableHash("claude:session-\($0)") }

        for scheme in [ColorScheme.light, .dark] {
            let grid = VStack(alignment: .leading, spacing: 10) {
                ForEach(AvatarStyle.allCases) { style in
                    HStack(spacing: 10) {
                        Text(style.title).font(.system(size: 12, weight: .semibold)).frame(width: 64, alignment: .leading)
                        ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                            AvatarView(seed: seeds[0], state: st, style: style, size: 44, animated: false, kind: .claude)
                        }
                        Divider().frame(height: 40)
                        ForEach(seeds.dropFirst(), id: \.self) { s in
                            AvatarView(seed: s, state: .working, style: style, size: 44, animated: false, kind: s % 2 == 0 ? .claude : .codex)
                        }
                    }
                }
            }
            .padding(20)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.92))
            .environment(\.colorScheme, scheme)
            write(grid, to: dir.appendingPathComponent("avatars-\(scheme == .dark ? "dark" : "light").png"))
        }

        for key in ["claude:demo-a", "claude:demo-b", "codex:demo-d"] {
            model.selectedKey = key
            let v = HUDRootView(model: model)
                .environment(\.solidBackground, true)
                .background(Color(white: 0.85))
            write(v, to: dir.appendingPathComponent("hud-\(key.replacingOccurrences(of: "claude:", with: "")).png"))
        }
        model.selectedKey = nil
        write(HUDRootView(model: model).environment(\.solidBackground, true).background(Color(white: 0.85)),
              to: dir.appendingPathComponent("hud-row.png"))
        model.selectedKey = "claude:demo-b"
        write(HUDRootView(model: model).environment(\.solidBackground, true).environment(\.colorScheme, .dark)
                .background(Color(white: 0.2)),
              to: dir.appendingPathComponent("hud-demo-b-dark.png"))
        // Настоящие AppKit-контролы ImageRenderer не рисует — снимаем живой NSHostingView.
        for (key, scheme) in [("claude:demo-a", "light"), ("claude:demo-b", "light"), ("codex:demo-d", "light"), ("claude:demo-b", "dark")] {
            model.selectedKey = key
            snapshot(HUDRootView(model: model).environment(\.solidBackground, true), dark: scheme == "dark",
                     to: dir.appendingPathComponent("live-\(key.replacingOccurrences(of: "claude:", with: ""))-\(scheme).png"))
        }
        // Панель в строке меню, светлая и тёмная.
        for dark in [false, true] {
            for tab in [0, 1] {
                snapshot(ControlPanelView(model: model, settings: settings,
                                          installed: [.claude: true, .codex: false], loginItem: true, tab: tab),
                         dark: dark, to: dir.appendingPathComponent("panel-\(tab)-\(dark ? "dark" : "light").png"))
            }
        }
        print("Превью сохранены в \(dir.path)")
    }

    /// Картинки для README: настоящие окна HUD и панели на демо-данных.
    static func renderReadme(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = Settings()
        settings.avatarStyle = .logo
        let model = AppModel(settings: settings)
        model.inject(Demo.events())

        // Главная картинка: HUD с запросом разрешения и панель в строке меню.
        model.selectedKey = "claude:demo-a"
        let hero = HStack(alignment: .top, spacing: 28) {
            HUDRootView(model: model)
            ControlPanelView(model: model, settings: settings, installed: [.claude: true, .codex: true], loginItem: true)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .padding(.top, 14)
        }
        .padding(28)
        .environment(\.solidBackground, true)
        snapshot(hero, dark: true, to: dir.appendingPathComponent("hero.png"), background: NSColor(srgbRed: 0x0E / 255.0, green: 0x0B / 255.0, blue: 0x14 / 255.0, alpha: 1))

        model.selectedKey = "claude:demo-b"
        snapshot(HUDRootView(model: model).padding(12).environment(\.solidBackground, true), dark: false,
                 to: dir.appendingPathComponent("question.png"), background: NSColor(srgbRed: 0xF7 / 255.0, green: 0xF6 / 255.0, blue: 0xFA / 255.0, alpha: 1))

        model.selectedKey = "codex:demo-d"
        snapshot(HUDRootView(model: model).padding(12).environment(\.solidBackground, true), dark: true,
                 to: dir.appendingPathComponent("done.png"), background: NSColor(srgbRed: 0x0E / 255.0, green: 0x0B / 255.0, blue: 0x14 / 255.0, alpha: 1))

        snapshot(ControlPanelView(model: model, settings: settings, installed: [.claude: true, .codex: true], loginItem: true, tab: 1),
                 dark: false, to: dir.appendingPathComponent("settings.png"))
        print("Картинки для README: \(dir.path)")
    }

    static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL) {
        snapshot(view, dark: dark, to: url, background: dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.85, alpha: 1))
    }

    static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL, background: NSColor) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = background
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Подложка окна в снимок не попадает — кладём на фон.
        let out = NSImage(size: host.bounds.size)
        out.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: host.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: host.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let r = NSBitmapImageRep(data: tiff),
           let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.close()
    }

    static func write<V: View>(_ view: V, to url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("Не удалось отрисовать \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}
