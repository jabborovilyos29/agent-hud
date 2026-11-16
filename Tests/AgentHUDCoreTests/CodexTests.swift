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
