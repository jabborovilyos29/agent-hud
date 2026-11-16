import Foundation

/// Адаптер Codex CLI: хуки из `~/.codex/hooks.json`.
/// Документация: https://learn.chatgpt.com/docs/hooks
///
/// Отличия от Claude Code:
/// - нет хука для вопросов агента — в HUD только статусы, шаги и разрешения;
/// - нет `Notification` и `PostToolUseFailure`, зато есть `Interrupt` (пользователь прервал ход);
/// - `PermissionRequest` нельзя отвечать с `updatedInput` — только allow/deny.
public struct CodexAdapter: AgentAdapter {
    public init() {}

    public var kind: AgentKind { .codex }

    public func shouldForward(mode: HookMode, payload: JSONValue) -> Bool {
        switch mode {
        case .event, .permission: return payload["session_id"]?.stringValue != nil
        case .question: return false
        }
    }

    public func events(from message: HookMessage, now: Date) -> [AgentEvent] {
        let p = message.payload
        guard let sid = p["session_id"]?.stringValue else { return [] }
        let name = p["hook_event_name"]?.stringValue ?? ""
        let toolName = p["tool_name"]?.stringValue ?? ""
        let input = p["tool_input"] ?? .object(JSONObject())
        let toolUseId = p["tool_use_id"]?.stringValue
        let deadline = message.deadline ?? HookTiming.deadline(now: now, hookTimeout: HookTiming.defaultTimeout)

        func make(_ body: AgentEvent.Body) -> AgentEvent {
            AgentEvent(kind: .codex, sessionId: sid, cwd: p["cwd"]?.stringValue,
                       transcriptPath: p["transcript_path"]?.stringValue,
                       agentId: name.hasPrefix("Subagent") ? nil : p["agent_id"]?.stringValue,
                       host: message.host.isEmpty ? nil : message.host, time: now, body: body)
        }

        if message.mode == .permission {
            return [make(.permissionRequested(requestId: message.requestId, toolName: toolName, input: input, deadline: deadline))]
        }
        guard message.mode == .event else { return [] }

        switch name {
        case "SessionStart":
            return [make(.sessionStarted(source: p["source"]?.stringValue, model: p["model"]?.stringValue))]
        case "UserPromptSubmit":
            let prompt = p["prompt"]?.stringValue ?? ""
            if Self.isAppGenerated(prompt) { return [make(.internalSession)] }
            return [make(.promptSubmitted(prompt))]
        case "PreToolUse":
            return [make(.toolStarted(toolName: toolName, input: input, toolUseId: toolUseId))]
        case "PostToolUse":
            return [make(.toolFinished(toolName: toolName, input: input, toolUseId: toolUseId,
                                       durationMs: nil, failed: Self.looksFailed(p["tool_response"])))]
        case "SubagentStart":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            return [make(.subagentStarted(agentId: aid, agentType: p["agent_type"]?.stringValue))]
        case "SubagentStop":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            return [make(.subagentStopped(agentId: aid))]
        case "Stop":
            return [make(.stopped(lastMessage: p["last_assistant_message"]?.stringValue, failed: false))]
        case "Interrupt":
            return [make(.interrupted)]
        case "SessionEnd":
            return [make(.sessionEnded(reason: p["reason"]?.stringValue))]
        default:
            return []
        }
    }

    public func hookOutput(for decision: Decision, mode: HookMode, payload: JSONValue) -> String? {
        guard mode == .permission else { return nil }
        switch decision {
        case .allow:
            return ClaudeCodeAdapter.permissionOutput(["behavior": "allow"])
        case .deny(let reason):
            let msg = (reason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Пользователь отклонил это действие в AgentHUD."
            return ClaudeCodeAdapter.permissionOutput(["behavior": "deny", "message": .string(msg)])
        case .answer, .passthrough:
            return nil
        }
    }

    /// Приложение Codex после каждого ответа запускает служебный тред (заголовки, подсказки)
    /// с промптом «This is an app-generated request…». Это не диалог пользователя.
    static func isAppGenerated(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("this is an app-generated request")
    }

    /// Ненулевой код выхода команды — шаг с ошибкой.
    static func looksFailed(_ response: JSONValue?) -> Bool {
        guard let r = response else { return false }
        if let code = r["exit_code"]?.intValue ?? r["exitCode"]?.intValue { return code != 0 }
        if let ok = r["success"]?.boolValue { return !ok }
        return false
    }

    public func summarize(toolName: String, input: JSONValue, cwd: String?) -> String {
        switch toolName {
        case "Bash", "shell", "exec_command", "local_shell", "unified_exec":
            let cmd = input["command"]?.stringValue
                ?? input["cmd"]?.stringValue
                ?? input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? ""
            let line = cmd.split(separator: "\n").first.map(String.init) ?? ""
            return "$ " + (line.count > 80 ? String(line.prefix(79)) + "…" : line)
        case "apply_patch", "Edit", "Write":
            let files = Self.patchFiles(input["command"]?.stringValue ?? input["patch"]?.stringValue ?? input["input"]?.stringValue ?? "")
                .map { ClaudeCodeAdapter.shortPath($0, cwd: cwd) }
            if files.isEmpty { return "Правка файлов" }
            return "Patch " + files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " +\(files.count - 3)" : "")
        case "update_plan": return "Обновил план"
        case "web_search": return "WebSearch \"\(input["query"]?.stringValue ?? "")\""
        case "view_image": return "Смотрит картинку"
        case "request_user_input", "request_user_input_async":
            let q = SessionStore.questionText(input) ?? ""
            return q.isEmpty ? "Вопрос пользователю" : "Вопрос: " + (q.count > 70 ? String(q.prefix(69)) + "…" : q)
        default:
            return ClaudeCodeAdapter().summarize(toolName: toolName, input: input, cwd: cwd)
        }
    }

    /// Файлы из патча формата Codex: `*** Update File: path`, `*** Add File:`, `*** Delete File:`.
    static func patchFiles(_ patch: String) -> [String] {
        var out: [String] = []
        for line in patch.split(separator: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                let f = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !out.contains(f) { out.append(f) }
            }
        }
        return out
    }
}
