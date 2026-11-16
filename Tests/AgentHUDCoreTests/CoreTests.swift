import Foundation
import Testing
@testable import AgentHUDCore

// MARK: - Помощники

func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/claude/\(name)", withExtension: "json"))
    return try JSONValue.parse(Data(contentsOf: url))
}

func message(_ name: String, mode: HookMode = .event, rid: String = "r1", deadline: Date? = nil,
             host: HostInfo = HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001", agentPid: 42)) throws -> HookMessage {
    HookMessage(agent: .claude, mode: mode, requestId: rid, deadline: deadline, host: host, payload: try fixture(name))
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let adapter = ClaudeCodeAdapter()

func events(_ m: HookMessage, at t: Date = t0) -> [AgentEvent] { adapter.events(from: m, now: t) }

// MARK: - JSON

@Suite struct JSONTests {
    @Test func roundTripPreservesOrderAndNumbers() throws {
        let text = """
        {
          "zeta": 1,
          "alpha": {
            "n": 3650,
            "f": 1.5e3,
            "s": "привет \\"мир\\" \\n\\t/ \\u00e9 😀",
            "arr": [],
            "obj": {}
          },
          "list": [
            true,
            false,
            null
          ]
        }
        """
        let v = try JSONValue.parse(text)
        #expect(v.objectValue?.keys == ["zeta", "alpha", "list"])
        #expect(v["alpha"]?["n"] == .number("3650"))
        #expect(v["alpha"]?["s"]?.stringValue == "привет \"мир\" \n\t/ é 😀")
        let again = try JSONValue.parse(v.pretty())
        #expect(again == v)
        #expect(v.pretty().contains("\"n\": 3650"))
        #expect(v.pretty().contains("\"arr\": []"))
    }

    @Test func surrogatePairs() throws {
        #expect(try JSONValue.parse("\"\\ud83d\\ude00\"").stringValue == "😀")
    }

    @Test func rejectsGarbage() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{\"a\":}") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{} x") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("\"open") }
    }

    @Test func compactEscapesControlChars() {
        let v: JSONValue = ["a": .string("x\u{01}y")]
        #expect(v.compact() == "{\"a\":\"x\\u0001y\"}")
    }

    @Test func objectSubscriptSetAndDelete() {
        var o = JSONObject()
        o["a"] = 1; o["b"] = 2; o["a"] = 3; o["b"] = nil
        #expect(o.keys == ["a"])
        #expect(o["a"] == .number("3"))
    }
}

// MARK: - Протокол

@Suite struct ProtocolTests {
    @Test func messageRoundTrip() throws {
        let m = try message("permission-PermissionRequest", mode: .permission, deadline: t0)
        let back = try #require(HookMessage.decode(m.encode()))
        #expect(back == m)
        #expect(!m.encode().contains("\n"))
    }

    @Test(arguments: [
        Decision.allow, .deny(reason: "нельзя"), .deny(reason: nil),
        .answer(["Цвет?": "Red, Blue"]), .passthrough,
    ])
    func replyRoundTrip(_ d: Decision) throws {
        let r = HookReply(requestId: "abc", decision: d)
        #expect(HookReply.decode(r.encode()) == r)
    }

    @Test func badMessagesAreRejected() {
        #expect(HookMessage.decode("not json") == nil)
        #expect(HookMessage.decode("{\"agent\":\"unknown\",\"mode\":\"event\",\"request_id\":\"x\",\"payload\":{}}") == nil)
    }

    @Test func deadlineKeepsSafetyMargin() {
        #expect(HookTiming.deadline(now: t0, hookTimeout: 600) == t0.addingTimeInterval(595))
        #expect(HookTiming.deadline(now: t0, hookTimeout: 2) == t0.addingTimeInterval(1))
    }
}

// MARK: - Адаптер Claude Code

@Suite struct ClaudeAdapterTests {
    @Test func mapsRealEvents() throws {
        let cases: [(String, (AgentEvent.Body) -> Bool)] = [
            ("SessionStart", { if case .sessionStarted(let src, let model) = $0 { return src == "startup" && model == "claude-haiku-5-5" }; return false }),
            ("UserPromptSubmit", { if case .promptSubmitted(let p) = $0 { return p.hasPrefix("First use") }; return false }),
            ("PreToolUse-Bash", { if case .toolStarted(let t, _, let id) = $0 { return t == "Bash" && id != nil }; return false }),
            ("PostToolUse-Bash", { if case .toolFinished(let t, _, _, let ms, let failed) = $0 { return t == "Bash" && ms != nil && !failed }; return false }),
            ("Stop", { if case .stopped(let msg, false) = $0 { return msg?.contains("Red") == true }; return false }),
            ("Notification-permission_prompt", { if case .notification("permission_prompt", _) = $0 { return true }; return false }),
        ]
        for (name, check) in cases {
            let e = try #require(events(try message(name)).first, "нет события для \(name)")
            #expect(check(e.body), "\(name): \(e.body)")
            #expect(e.sessionId == "11111111-2222-3333-4444-555555555555")
            #expect(e.cwd == "/Users/dev/project")
        }
    }

    @Test func permissionAndQuestionModes() throws {
        let p = try #require(events(try message("permission-PermissionRequest", mode: .permission, rid: "p1", deadline: t0)).first)
        guard case .permissionRequested("p1", "Bash", let input, t0) = p.body else { Issue.record("\(p.body)"); return }
        #expect(input["command"]?.stringValue?.contains("node -e") == true)

        let q = try #require(events(try message("question-PreToolUse-AskUserQuestion", mode: .question, rid: "q1", deadline: t0)).first)
        guard case .questionAsked("q1", let qs, _, _) = q.body else { Issue.record("\(q.body)"); return }
        #expect(qs.count == 1)
        #expect(qs[0].options.map(\.label) == ["Red", "Green", "Blue"])
        #expect(qs[0].header == "Цвет")
    }

    @Test func shouldForward() throws {
        #expect(adapter.shouldForward(mode: .permission, payload: try fixture("permission-PermissionRequest")))
        var ask = try fixture("permission-PermissionRequest")
        ask["tool_name"] = "AskUserQuestion"
        #expect(!adapter.shouldForward(mode: .permission, payload: ask))
        ask["tool_name"] = "ExitPlanMode"
        #expect(!adapter.shouldForward(mode: .permission, payload: ask))
        #expect(adapter.shouldForward(mode: .question, payload: try fixture("question-PreToolUse-AskUserQuestion")))
        #expect(!adapter.shouldForward(mode: .question, payload: try fixture("PreToolUse-Bash")))
    }

    @Test func permissionOutputs() throws {
        let payload = try fixture("permission-PermissionRequest")
        let allow = try JSONValue.parse(try #require(adapter.hookOutput(for: .allow, mode: .permission, payload: payload)))
        #expect(allow["hookSpecificOutput"]?["hookEventName"] == "PermissionRequest")
        #expect(allow["hookSpecificOutput"]?["decision"]?["behavior"] == "allow")

        let deny = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: "  опасно "), mode: .permission, payload: payload)))
        #expect(deny["hookSpecificOutput"]?["decision"]?["behavior"] == "deny")
        #expect(deny["hookSpecificOutput"]?["decision"]?["message"] == "опасно")

        let denyEmpty = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: ""), mode: .permission, payload: payload)))
        #expect(denyEmpty["hookSpecificOutput"]?["decision"]?["message"]?.stringValue?.isEmpty == false)

        #expect(adapter.hookOutput(for: .passthrough, mode: .permission, payload: payload) == nil)
        #expect(adapter.hookOutput(for: .allow, mode: .event, payload: payload) == nil)
    }

    @Test func questionOutputEchoesQuestionsAndAddsAnswers() throws {
        let payload = try fixture("question-PreToolUse-AskUserQuestion")
        let q = try #require(payload["tool_input"]?["questions"]?[0]?["question"]?.stringValue)
        let out = try JSONValue.parse(try #require(
            adapter.hookOutput(for: .answer([q: "Green, Blue", "лишний": "x"]), mode: .question, payload: payload)))
        let hso = try #require(out["hookSpecificOutput"])
        #expect(hso["hookEventName"] == "PreToolUse")
        #expect(hso["permissionDecision"] == "allow")
        #expect(hso["updatedInput"]?["questions"] == payload["tool_input"]?["questions"])
        #expect(hso["updatedInput"]?["answers"]?.objectValue?.keys == [q])
        #expect(hso["updatedInput"]?["answers"]?[q] == "Green, Blue")
        // allow без ответа бессмысленен — пусть спросит терминал
        #expect(adapter.hookOutput(for: .allow, mode: .question, payload: payload) == nil)
        #expect(adapter.hookOutput(for: .passthrough, mode: .question, payload: payload) == nil)
    }

    @Test func summaries() {
        func s(_ t: String, _ i: JSONValue) -> String { adapter.summarize(toolName: t, input: i, cwd: "/p") }
        #expect(s("Bash", ["command": "npm test\nsecond line"]) == "$ npm test")
        #expect(s("Read", ["file_path": "/p/src/a.ts"]) == "Read src/a.ts")
        #expect(s("Edit", ["file_path": "/other/b.ts"]) == "Edit /other/b.ts")
        #expect(s("Grep", ["pattern": "foo"]) == "Grep \"foo\"")
        #expect(s("WebFetch", ["url": "https://example.com/x"]) == "WebFetch example.com")
        #expect(s("mcp__brain__search", ["query": "x"]) == "brain · search")
        #expect(s("mcp__claude-in-chrome__tabs_create_mcp", [:]) == "claude-in-chrome · tabs_create_mcp")
        #expect(s("Task", ["description": "Найти баг"]) == "Агент: Найти баг")
        #expect(s("Unknown", [:]) == "Unknown")
    }
}

// MARK: - Хранилище сессий

@Suite struct SessionStoreTests {
    func run(_ names: [(String, HookMode, String)], store: inout SessionStore, start: Date = t0) throws -> [String] {
        var released: [String] = []
        for (k, (name, mode, rid)) in names.enumerated() {
            let t = start.addingTimeInterval(TimeInterval(k))
            for e in events(try message(name, mode: mode, rid: rid, deadline: t.addingTimeInterval(595)), at: t) {
                released += store.apply(e)
            }
        }
        return released
    }

    var key: String { "claude:11111111-2222-3333-4444-555555555555" }

    @Test func fullHappyPath() throws {
        var st = SessionStore()
        _ = try run([("SessionStart", .event, "a"), ("UserPromptSubmit", .event, "b")], store: &st)
        var s = try #require(st.session(key))
        #expect(s.state == .working)
        #expect(s.title.hasPrefix("First use the AskUserQuestion"))
        #expect(s.host.tty == "/dev/ttys001")
        #expect(s.projectName == "project")

        _ = try run([("PreToolUse-AskUserQuestion", .event, "c"), ("question-PreToolUse-AskUserQuestion", .question, "q1")], store: &st)
        #expect(st.session(key)?.state == .waitingAnswer)
        #expect(st.openRequestCount == 1)
        st.markAnswered("q1")
        #expect(st.session(key)?.state == .working)

        _ = try run([("PostToolUse-AskUserQuestion", .event, "d"), ("PreToolUse-Bash", .event, "e"),
                     ("permission-PermissionRequest", .permission, "p1")], store: &st)
        #expect(st.session(key)?.state == .waitingPermission)
        // Уведомление permission_prompt не перебивает открытый запрос
        _ = try run([("Notification-permission_prompt", .event, "n")], store: &st)
        #expect(st.session(key)?.activePending?.id == "p1")
        st.markAnswered("p1")
        _ = try run([("PostToolUse-Bash", .event, "f"), ("Stop", .event, "g")], store: &st)
        s = try #require(st.session(key))
        #expect(s.state == .done)
        #expect(s.lastMessage?.contains("Red") == true)
        #expect(s.steps.map(\.toolName) == ["AskUserQuestion", "Bash"])
        #expect(s.steps.allSatisfy { $0.status == .ok })
        #expect(s.steps[1].durationMs != nil)
    }

    @Test func answeredInTerminalReleasesHook() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("PreToolUse-Bash", .event, "b"),
                     ("permission-PermissionRequest", .permission, "p1")], store: &st)
        #expect(st.session(key)?.state == .waitingPermission)
        let released = try run([("PostToolUse-Bash", .event, "c")], store: &st)
        #expect(released == ["p1"])
        #expect(st.session(key)?.activePending == nil)
        #expect(st.session(key)?.state == .working)
    }

    @Test func stopReleasesOpenRequests() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("permission-PermissionRequest", .permission, "p1")], store: &st)
        let released = try run([("Stop", .event, "b")], store: &st)
        #expect(released == ["p1"])
        #expect(st.session(key)?.state == .done)
    }

    @Test func connectionClosedBeforeDeadlineMeansAnsweredElsewhere() throws {
        var st = SessionStore()
        _ = try run([("permission-PermissionRequest", .permission, "p1")], store: &st)
        st.connectionClosed("p1", now: t0.addingTimeInterval(10))
        #expect(st.session(key)?.pending.isEmpty == true)
    }

    @Test func expiryByConnectionCloseAndByTick() throws {
        var st = SessionStore()
        _ = try run([("permission-PermissionRequest", .permission, "p1")], store: &st)
        st.connectionClosed("p1", now: t0.addingTimeInterval(594))
        #expect(st.session(key)?.state == .expired)

        var st2 = SessionStore()
        _ = try run([("question-PreToolUse-AskUserQuestion", .question, "q1")], store: &st2)
        #expect(st2.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: nil).isEmpty)
        #expect(st2.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil) == ["q1"])
        #expect(st2.session(key)?.state == .expired)
        // Сессия пошла дальше — просроченное окошко исчезает
        _ = try run([("PostToolUse-AskUserQuestion", .event, "x")], store: &st2, start: t0.addingTimeInterval(600))
        #expect(st2.session(key)?.state == .working)
    }

    @Test func notificationWithoutPendingMeansWaitingInTerminal() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("Notification-permission_prompt", .event, "n")], store: &st)
        let s = try #require(st.session(key))
        #expect(s.state == .waitingPermission)
        #expect(s.activePending == nil)
        _ = try run([("PostToolUse-Bash", .event, "c")], store: &st)
        #expect(st.session(key)?.state == .working)
    }

    @Test func sessionEndRemovesAfterLinger() throws {
        var st = SessionStore()
        _ = try run([("SessionStart", .event, "a")], store: &st)
        var p = try fixture("Stop"); p["hook_event_name"] = "SessionEnd"; p["reason"] = "prompt_input_exit"
        for e in adapter.events(from: HookMessage(agent: .claude, mode: .event, requestId: "z", deadline: nil, host: HostInfo(), payload: p), now: t0) {
            st.apply(e)
        }
        #expect(st.session(key)?.state == .ended)
        st.tick(now: t0.addingTimeInterval(1), autoHideDoneAfter: nil)
        #expect(st.session(key) != nil)
        st.tick(now: t0.addingTimeInterval(5), autoHideDoneAfter: nil)
        #expect(st.session(key) == nil)
        #expect(st.order.isEmpty)
    }

    @Test func autoHideDone() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("Stop", .event, "b")], store: &st)
        st.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: 60)
        #expect(st.visibleSessions.isEmpty)
        // Новый промпт снова показывает сессию
        _ = try run([("UserPromptSubmit", .event, "c")], store: &st, start: t0.addingTimeInterval(200))
        #expect(st.visibleSessions.count == 1)
    }

    @Test func stepsAreCapped() throws {
        var st = SessionStore()
        let base = try message("PreToolUse-Bash")
        for i in 0..<(AgentSession.maxSteps + 20) {
            var m = base
            m.payload["tool_use_id"] = .string("t\(i)")
            for e in events(m) { st.apply(e) }
        }
        #expect(st.session(key)?.steps.count == AgentSession.maxSteps)
        #expect(st.session(key)?.steps.last?.id == "t\(AgentSession.maxSteps + 19)")
    }

    @Test func subagentSteps() throws {
        var st = SessionStore()
        var p = try fixture("Stop")
        p["hook_event_name"] = "SubagentStart"; p["agent_id"] = "ag1"; p["agent_type"] = "Explore"
        let m = HookMessage(agent: .claude, mode: .event, requestId: "s", deadline: nil, host: HostInfo(), payload: p)
        for e in events(m) { st.apply(e) }
        #expect(st.session(key)?.steps.first?.summary == "Субагент: Explore")
        p["hook_event_name"] = "SubagentStop"
        for e in events(HookMessage(agent: .claude, mode: .event, requestId: "s2", deadline: nil, host: HostInfo(), payload: p), at: t0.addingTimeInterval(3)) {
            st.apply(e)
        }
        #expect(st.session(key)?.steps.first?.status == .ok)
        #expect(st.session(key)?.steps.first?.durationMs == 3000)
    }
}

// MARK: - Установщик хуков

@Suite struct InstallerTests {
    let foreign = """
    {
      "env": {
        "A": "1"
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "bash ~/.claude/hooks/guard.sh",
                "timeout": 5
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "~/.claude/hooks/herdr-agent-state.sh session"
              }
            ]
          }
        ]
      },
      "model": "opus"
    }

    """

    let installer = ClaudeHookInstaller(hookPath: "/Users/dev/.local/bin/agenthud-hook", timeout: 600)

    @Test func installKeepsForeignHooksAndOrder() throws {
        let before = try JSONValue.parse(foreign)
        let after = installer.install(into: before)
        #expect(after.objectValue?.keys == ["env", "hooks", "model"])
        let pre = try #require(after["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 3)
        #expect(pre[0]["hooks"]?[0]?["command"] == "bash ~/.claude/hooks/guard.sh")
        #expect(pre[1]["matcher"] == "AskUserQuestion")
        #expect(pre[1]["hooks"]?[0]?["command"] == "/Users/dev/.local/bin/agenthud-hook claude question --timeout 600")
        #expect(pre[1]["hooks"]?[0]?["timeout"] == 600)
        #expect(pre[2]["hooks"]?[0]?["async"] == true)
        let perm = try #require(after["hooks"]?["PermissionRequest"]?.arrayValue)
        #expect(perm[0]["hooks"]?[0]?["command"]?.stringValue?.hasSuffix("claude permission --timeout 600") == true)
        #expect(after["hooks"]?["Stop"]?[0]?["matcher"] == nil)
        #expect(ClaudeHookInstaller.isInstalled(in: after))
        #expect(!ClaudeHookInstaller.isInstalled(in: before))
    }

    @Test func installIsIdempotentAndUninstallRestores() throws {
        let before = try JSONValue.parse(foreign)
        let once = installer.install(into: before)
        let twice = installer.install(into: once)
        #expect(once == twice)
        let removed = ClaudeHookInstaller.uninstall(from: twice)
        #expect(removed == before)
        #expect(removed.pretty() + "\n" == foreign)
    }

    @Test func uninstallKeepsMixedGroups() throws {
        let mixed: JSONValue = ["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "other"],
            ["type": "command", "command": "/x/agenthud-hook claude event"],
        ]]]]]
        let r = ClaudeHookInstaller.uninstall(from: mixed)
        #expect(r["hooks"]?["Stop"]?[0]?["hooks"]?.arrayValue?.count == 1)
        #expect(r["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"] == "other")
    }

    @Test func pathsWithSpacesAreQuoted() {
        let i = ClaudeHookInstaller(hookPath: "/Users/dev/My Apps/agenthud-hook", timeout: 30)
        #expect(i.command(.event) == "'/Users/dev/My Apps/agenthud-hook' claude event")
    }

    @Test func fileApplyMakesBackupAndPreservesFormatting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try foreign.write(to: file, atomically: true, encoding: .utf8)

        let r = try ClaudeHookInstaller.apply(file: file, now: t0) { installer.install(into: $0) }
        let backup = try #require(r.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == foreign)
        #expect(ClaudeHookInstaller.isInstalled(in: try JSONValue.parse(Data(contentsOf: file))))

        let r2 = try ClaudeHookInstaller.apply(file: file, now: t0.addingTimeInterval(1)) { ClaudeHookInstaller.uninstall(from: $0) }
        #expect(r2.backup != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == foreign)

        // Без изменений — без записи и без бэкапа
        let r3 = try ClaudeHookInstaller.apply(file: file) { $0 }
        #expect(r3.backup == nil)
    }

    @Test func missingFileIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try ClaudeHookInstaller.apply(file: file) { installer.install(into: $0) }
        #expect(ClaudeHookInstaller.isInstalled(in: try JSONValue.parse(Data(contentsOf: file))))
    }
}

// MARK: - HostProbe

@Suite struct HostProbeTests {
    @Test func agentIsFirstNonShellAncestor() {
        let chain = [
            HostProbe.ProcInfo(pid: 10, ppid: 9, tty: "/dev/ttys001", name: "sh"),
            HostProbe.ProcInfo(pid: 9, ppid: 8, tty: "/dev/ttys001", name: "2.1.322"),
            HostProbe.ProcInfo(pid: 8, ppid: 1, tty: "/dev/ttys001", name: "zsh"),
        ]
        #expect(HostProbe.agentProcess(in: chain)?.pid == 9)
    }

    @Test func currentProcessHasChain() {
        let h = HostProbe.current(env: [:])
        #expect(h.agentPid != nil)
        #expect(!h.processChain.isEmpty)
        let herdr = HostProbe.current(env: ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p2", "HERDR_SOCKET_PATH": "/s"])
        #expect(herdr.herdrPaneId == "w1:p2")
    }

    @Test func labels() {
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001").label == "Terminal")
        #expect(HostInfo(tty: "/dev/ttys001", herdrPaneId: "p").label == "herdr")
        // Терминал, запущенный из приложения, остаётся терминалом.
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001", appBundleId: HostInfo.claudeDesktop).label == "Terminal")
        #expect(HostInfo(appBundleId: HostInfo.codexDesktop).label == "приложение Codex")
    }
}

@Suite struct InteractiveFilterTests {
    let tty = HostInfo(tty: "/dev/ttys001")
    let claudeApp = HostInfo(appBundleId: HostInfo.claudeDesktop, appName: "Claude", hostSessionId: "local_1")
    let codexApp = HostInfo(appBundleId: HostInfo.codexDesktop, appName: "Codex")

    @Test func terminalSessions() {
        #expect(HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]))
        #expect(HostProbe.isInteractive(kind: .claude, host: tty, env: [:]))
        #expect(HostProbe.isInteractive(kind: .codex, host: tty, env: [:]))
    }

    @Test func desktopSessions() {
        #expect(HostProbe.isInteractive(kind: .claude, host: claudeApp,
                                        env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_HOST_SESSION_ID": "local_1"]))
        #expect(HostProbe.isInteractive(kind: .codex, host: codexApp, env: [:]))
        #expect(claudeApp.isDesktopApp && codexApp.isDesktopApp && !tty.isDesktopApp)
        #expect(claudeApp.label == "приложение Claude")
    }

    @Test func automationIsSkipped() {
        // Служебный запрос приложения Claude — без id сессии
        #expect(!HostProbe.isInteractive(kind: .claude, host: claudeApp, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: HostInfo(), env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]))
        // codex exec из скрипта: ни TTY, ни приложения
        #expect(!HostProbe.isInteractive(kind: .codex, host: HostInfo(), env: [:]))
        #expect(HostProbe.isInteractive(kind: .codex, host: HostInfo(), env: ["AGENTHUD_ANY_HOST": "1"]))
    }

    @Test func bundleFromExecutable() {
        #expect(HostProbe.bundlePath(forExecutable: "/Applications/Claude.app/Contents/MacOS/Claude") == "/Applications/Claude.app")
        #expect(HostProbe.bundlePath(forExecutable: "/usr/bin/zsh") == nil)
    }

    @Test func hostRoundTrip() {
        let h = HostInfo(tty: nil, agentPid: 5, appBundleId: HostInfo.codexDesktop, appName: "Codex", hostSessionId: "x")
        #expect(HostInfo(json: h.toJSON()) == h)
    }
}
