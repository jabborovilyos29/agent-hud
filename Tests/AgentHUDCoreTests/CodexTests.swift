import Foundation
import Testing
@testable import AgentHUDCore

func codexFixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/codex/\(name)", withExtension: "json"))
    return try JSONValue.parse(Data(contentsOf: url))
}

@Suite struct CodexTests {
    let codex = CodexAdapter()
    let key = "codex:cdx-1111"

    func msg(_ name: String, mode: HookMode = .event, rid: String = "r") throws -> HookMessage {
        HookMessage(agent: .codex, mode: mode, requestId: rid, deadline: t0.addingTimeInterval(595),
                    host: HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys009", agentPid: 7), payload: try codexFixture(name))
    }

    func apply(_ names: [(String, HookMode)], _ st: inout SessionStore) throws -> [String] {
        var rel: [String] = []
        for (i, (n, m)) in names.enumerated() {
            for e in codex.events(from: try msg(n, mode: m, rid: "\(n)-\(i)"), now: t0.addingTimeInterval(TimeInterval(i))) {
                rel += st.apply(e, adapter: codex)
            }
        }
        return rel
    }

    @Test func fullSession() throws {
        var st = SessionStore()
        _ = try apply([("SessionStart", .event), ("UserPromptSubmit", .event), ("PreToolUse-Bash", .event)], &st)
        var s = try #require(st.session(key))
        #expect(s.kind == .codex)
        #expect(s.model == "gpt-5.5-codex")
        #expect(s.title == "Почини тесты в проекте")
        #expect(s.state == .working)
        #expect(s.steps.first?.summary == "$ npm test")

        _ = try apply([("PostToolUse-Bash", .event)], &st)
        #expect(st.session(key)?.steps.first?.status == .failed)   // exit_code 1

        _ = try apply([("PreToolUse-apply_patch", .event)], &st)
        #expect(st.session(key)?.steps.last?.summary == "Patch src/a.ts, docs/b.md")

        _ = try apply([("Stop", .event)], &st)
        s = try #require(st.session(key))
        #expect(s.state == .done)
        #expect(s.lastMessage == "Тесты починены.")

        _ = try apply([("SessionEnd", .event)], &st)
        #expect(st.session(key)?.state == .ended)
    }

    @Test func permissionFlow() throws {
        var st = SessionStore()
        _ = try apply([("UserPromptSubmit", .event), ("permission-PermissionRequest", .permission)], &st)
        #expect(st.session(key)?.state == .waitingPermission)
        let payload = try codexFixture("permission-PermissionRequest")
        let allow = try JSONValue.parse(try #require(codex.hookOutput(for: .allow, mode: .permission, payload: payload)))
        #expect(allow["hookSpecificOutput"]?["decision"] == ["behavior": "allow"])
        // Codex закрывает с ошибкой, если в ответе есть updatedInput — его быть не должно.
        #expect(allow["hookSpecificOutput"]?["decision"]?["updatedInput"] == nil)
        let deny = try JSONValue.parse(try #require(codex.hookOutput(for: .deny(reason: "нет"), mode: .permission, payload: payload)))
        #expect(deny["hookSpecificOutput"]?["decision"] == ["behavior": "deny", "message": "нет"])
        #expect(codex.hookOutput(for: .passthrough, mode: .permission, payload: payload) == nil)
    }

    @Test func interruptMakesIdle() throws {
        var st = SessionStore()
        _ = try apply([("UserPromptSubmit", .event), ("PreToolUse-Bash", .event), ("permission-PermissionRequest", .permission)], &st)
        let released = try apply([("Interrupt", .event)], &st)
        #expect(released.count == 1)
        #expect(st.session(key)?.state == .idle)
        #expect(st.session(key)?.steps.first?.status == .failed)
    }

    @Test func questionsAreNotForwarded() throws {
        #expect(!codex.shouldForward(mode: .question, payload: try codexFixture("PreToolUse-Bash")))
        #expect(codex.shouldForward(mode: .permission, payload: try codexFixture("permission-PermissionRequest")))
    }

    @Test func installerForCodex() throws {
        let inst = HookInstaller(agent: .codex, hookPath: "/Users/dev/.local/bin/agenthud-hook", timeout: 300)
        let existing: JSONValue = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "orca stop", "timeout": 10]]]]]]
        let after = inst.install(into: existing)
        #expect(after["hooks"]?["Stop"]?.arrayValue?.count == 2)
        #expect(after["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"] == "orca stop")
        #expect(after["hooks"]?["PermissionRequest"]?[0]?["hooks"]?[0]?["command"] == "/Users/dev/.local/bin/agenthud-hook codex permission --timeout 300")
        let end = try #require(after["hooks"]?["SessionEnd"]?[0]?["hooks"]?[0])
        #expect(end["timeout"] == 3)
        #expect(end["async"] == nil)
        #expect(after["hooks"]?["Notification"] == nil)
        #expect(after["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)   // без отдельного хука вопросов
        #expect(HookInstaller.uninstall(from: after) == existing)
    }
}

/// Последовательность из живого лога приложения Codex (2026-11-16): диалог thread-main
/// и служебный тред thread-helper после каждого ответа.
@Suite struct CodexDesktopTests {
    let codex = CodexAdapter()
    let app = HostInfo(agentPid: 1, appBundleId: HostInfo.codexDesktop, appName: "Codex")

    func ev(_ sid: String, _ event: String, _ extra: JSONValue = [:], at t: Double) -> [AgentEvent] {
        var p: JSONValue = ["session_id": .string(sid), "cwd": "/Users/dev/codex-demo-todo", "hook_event_name": .string(event)]
        for e in extra.objectValue?.entries ?? [] { p[e.key] = e.value }
        return codex.events(from: HookMessage(agent: .codex, mode: .event, requestId: "r", deadline: nil, host: app, payload: p),
                            now: t0.addingTimeInterval(t))
    }

    @Test func helperThreadIsHiddenAndDialogSurvivesSessionEnd() {
        var st = SessionStore()
        let main = "codex:thread-main", helper = "codex:thread-helper"
        func run(_ es: [AgentEvent]) { for e in es { st.apply(e, adapter: codex) } }

        run(ev("thread-main", "SessionStart", ["source": "startup"], at: 0))
        #expect(st.visibleSessions.isEmpty)            // до промпта тред не показываем
        run(ev("thread-main", "UserPromptSubmit", ["prompt": "это тест: сделай на него любой ответ"], at: 1))
        run(ev("thread-main", "Stop", ["last_assistant_message": "Ок"], at: 3))
        // Служебный тред
        run(ev("thread-helper", "SessionStart", ["source": "startup"], at: 4))
        #expect(st.visibleSessions.map(\.id) == [main])
        run(ev("thread-helper", "UserPromptSubmit", ["prompt": "This is an app-generated request for a thread title."], at: 4.2))
        #expect(st.visibleSessions.map(\.id) == [main])
        #expect(st.session(helper) == nil)
        run(ev("thread-helper", "Interrupt", at: 12))
        run(ev("thread-helper", "SessionEnd", ["reason": "other"], at: 12.1))
        #expect(st.session(helper) == nil)

        // Вопрос через request_user_input_async: ход закончился, но агент ждёт ответа
        run(ev("thread-main", "UserPromptSubmit", ["prompt": "спроси меня цвет"], at: 20))
        let input: JSONValue = ["questions": [["question": "Какой цвет выбрать?"]]]
        run(ev("thread-main", "PreToolUse", ["tool_name": "request_user_input_async", "tool_use_id": "c1", "tool_input": input], at: 22))
        run(ev("thread-main", "PostToolUse", ["tool_name": "request_user_input_async", "tool_use_id": "c1", "tool_input": input], at: 22.02))
        run(ev("thread-main", "Stop", ["last_assistant_message": "Выбери цвет кнопкой"], at: 25))
        var s = st.session(main)!
        #expect(s.state == .waitingAnswer)
        #expect(s.waitingNote == "Какой цвет выбрать?")
        #expect(s.steps.last?.summary == "Вопрос: Какой цвет выбрать?")

        // Ответ пришёл новым промптом → снова работает, потом готово
        run(ev("thread-main", "UserPromptSubmit", ["prompt": "красный"], at: 50))
        #expect(st.session(main)?.state == .working)
        #expect(st.session(main)?.waitingNote == nil)
        run(ev("thread-main", "Stop", ["last_assistant_message": "Принял: красный"], at: 53))
        #expect(st.session(main)?.state == .done)

        // Приложение выгружает тред — диалог не исчезает
        run(ev("thread-main", "SessionEnd", ["reason": "other"], at: 55))
        st.tick(now: t0.addingTimeInterval(70), autoHideDoneAfter: 1800)
        s = st.session(main)!
        #expect(s.state == .done)
        #expect(st.visibleSessions.count == 1)
        #expect(s.title == "это тест: сделай на него любой ответ")
    }

    @Test func terminalCodexSessionEndStillEnds() {
        var st = SessionStore()
        let tty = HostInfo(tty: "/dev/ttys002")
        for (name, extra) in [("UserPromptSubmit", ["prompt": "x"] as JSONValue), ("SessionEnd", ["reason": "other"])] {
            var p: JSONValue = ["session_id": "t1", "cwd": "/p", "hook_event_name": .string(name)]
            for e in extra.objectValue!.entries { p[e.key] = e.value }
            for e in codex.events(from: HookMessage(agent: .codex, mode: .event, requestId: "r", deadline: nil, host: tty, payload: p), now: t0) {
                st.apply(e, adapter: codex)
            }
        }
        #expect(st.session("codex:t1")?.state == .ended)
    }
}

/// Codex с `approvals_reviewer = auto_review`: запросы решает встроенный ревьюер, хук он не ждёт.
@Suite struct CodexAutoReviewTests {
    let codex = CodexAdapter()
    let app = HostInfo(agentPid: 1, appBundleId: HostInfo.codexDesktop, appName: "Codex")

    func makeRollout(_ reviewers: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-rollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("rollout-2026-11-16T11-53-52-th1.jsonl")
        var lines = [#"{"type":"session_meta","payload":{"id":"th1"}}"#]
        for r in reviewers {
            lines.append(#"{"type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"\#(r)"}}"#)
            lines.append(#"{"type":"response_item","payload":{"type":"message","text":"…"}}"#)
        }
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        return f
    }

    func ev(_ name: String, _ extra: JSONValue, mode: HookMode = .event, rid: String = "r", at t: Double, rollout: URL) -> [AgentEvent] {
        var p: JSONValue = ["session_id": "th1", "cwd": "/p", "hook_event_name": .string(name), "transcript_path": .string(rollout.path)]
        for e in extra.objectValue?.entries ?? [] { p[e.key] = e.value }
        return codex.events(from: HookMessage(agent: .codex, mode: mode, requestId: rid, deadline: t0.addingTimeInterval(600),
                                              host: app, payload: p), now: t0.addingTimeInterval(t))
    }

    @Test func reviewerIsReadFromRolloutLastValueWins() throws {
        #expect(CodexAdapter.approvalsReviewer(sessionId: "th1", transcriptPath: try makeRollout(["auto_review"]).path) == "auto_review")
        #expect(CodexAdapter.approvalsReviewer(sessionId: "th1", transcriptPath: try makeRollout(["auto_review", "user"]).path) == "user")
        #expect(CodexAdapter.approvalsReviewer(sessionId: "th1", transcriptPath: "/nonexistent", sessionsRoot: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func rolloutIsFoundBySessionIdWithoutTranscriptPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-sessions-\(UUID().uuidString)")
        let c = Calendar.current.dateComponents([.year, .month, .day], from: t0)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"payload":{"approvals_reviewer":"auto_review"}}"#.write(to: dir.appendingPathComponent("rollout-x-0123456789ab.jsonl"), atomically: true, encoding: .utf8)
        #expect(CodexAdapter.approvalsReviewer(sessionId: "0123456789ab", transcriptPath: nil, sessionsRoot: root, now: t0) == "auto_review")
    }

    @Test func autoReviewedRequestDoesNotWaitForUser() throws {
        let rollout = try makeRollout(["auto_review"])
        var st = SessionStore()
        func run(_ es: [AgentEvent]) -> [String] { es.flatMap { st.apply($0, adapter: codex) } }
        _ = run(ev("UserPromptSubmit", ["prompt": "сделай субтитры"], at: 0, rollout: rollout))
        let cmd = "node qa/inspect-studio.cjs"
        _ = run(ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": .string(cmd), "description": "Проверить Studio?"]],
                   mode: .permission, rid: "p1", at: 1, rollout: rollout))
        var s = try #require(st.session("codex:th1"))
        #expect(s.activePending?.autoReview == true)
        #expect(s.state == .working)              // не «Ждёт разрешения»
        #expect(st.openRequestCount == 0)          // не считается ожиданием пользователя

        // Параллельно выполнилась другая команда — запрос не снимается
        var rel = run(ev("PostToolUse", ["tool_name": "Bash", "tool_use_id": "c9", "tool_input": ["command": "ls"]], at: 5, rollout: rollout))
        #expect(rel.isEmpty)
        #expect(st.session("codex:th1")?.activePending?.id == "p1")

        // Ревьюер одобрил — выполнилась именно эта команда (уже без description)
        rel = run(ev("PostToolUse", ["tool_name": "Bash", "tool_use_id": "c1", "tool_input": ["command": .string(cmd)]], at: 30, rollout: rollout))
        #expect(rel == ["p1"])
        s = try #require(st.session("codex:th1"))
        #expect(s.activePending == nil)
    }

    @Test func rejectedByReviewerIsDroppedAfterLinger() throws {
        let rollout = try makeRollout(["auto_review"])
        var st = SessionStore()
        for e in ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf /tmp/x"]], mode: .permission, rid: "p2", at: 0, rollout: rollout) {
            st.apply(e, adapter: codex)
        }
        #expect(st.dropStaleAutoReviews(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(st.dropStaleAutoReviews(now: t0.addingTimeInterval(91)) == ["p2"])
        #expect(st.session("codex:th1")?.pending.isEmpty == true)
    }

    @Test func userReviewerStillWaitsForUser() throws {
        let rollout = try makeRollout(["user"])
        var st = SessionStore()
        for e in ev("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm publish"]], mode: .permission, rid: "p3", at: 0, rollout: rollout) {
            st.apply(e, adapter: codex)
        }
        #expect(st.session("codex:th1")?.state == .waitingPermission)
        #expect(st.openRequestCount == 1)
    }
}

/// Параллельные команды одного инструмента не должны снимать чужой запрос.
@Suite struct PendingMatchingTests {
    @Test func claudeParallelBashDoesNotResolveOtherRequest() throws {
        var st = SessionStore()
        let a = ClaudeCodeAdapter()
        func pay(_ name: String, _ cmd: String) -> JSONValue {
            ["session_id": "s1", "cwd": "/p", "hook_event_name": .string(name), "tool_name": "Bash", "tool_use_id": .string(cmd),
             "tool_input": ["command": .string(cmd)]]
        }
        for e in a.events(from: HookMessage(agent: .claude, mode: .permission, requestId: "p1", deadline: t0.addingTimeInterval(600), host: HostInfo(), payload: pay("PermissionRequest", "npm publish")), now: t0) { st.apply(e) }
        var rel = a.events(from: HookMessage(agent: .claude, mode: .event, requestId: "e", deadline: nil, host: HostInfo(), payload: pay("PostToolUse", "ls")), now: t0).flatMap { st.apply($0) }
        #expect(rel.isEmpty)
        rel = a.events(from: HookMessage(agent: .claude, mode: .event, requestId: "e", deadline: nil, host: HostInfo(), payload: pay("PostToolUse", "npm publish")), now: t0).flatMap { st.apply($0) }
        #expect(rel == ["p1"])
    }
}
