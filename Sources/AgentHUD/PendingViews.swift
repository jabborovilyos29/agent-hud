import AgentHUDCore
import SwiftUI

// MARK: - Разрешение

struct PermissionView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest
    let tool: String
    let input: JSONValue

    @State private var denying = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.autoReview {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Color.accentColor)
                    Text("Codex проверяет запрос сам: \(toolTitle)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Text("Включён авто-ревью: встроенный ревьюер решит сам, обычно за 15–30 с. Можно ответить раньше.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Просит разрешение: \(toolTitle)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Countdown(deadline: request.deadline)
                }
            }
            ToolDetail(tool: tool, input: input, cwd: session.cwd)
            if denying {
                HStack(spacing: 6) {
                    TextField("Почему (необязательно)", text: $reason)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($reasonFocused)
                        .onSubmit { deny() }
                    Button("Отклонить", role: .destructive) { deny() }
                    Button("Отмена") { denying = false }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button { model.decide(request.id, .allow) } label: {
                        Label("Разрешить", systemImage: "checkmark").frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Разрешить один раз (⌘↩)")
                    if !ruleOptions.isEmpty {
                        AlwaysMenu(options: ruleOptions) { o in model.decide(request.id, .allowWith([o.update])) }
                    }
                    Button("Отклонить…") { denying = true; reasonFocused = true }
                    Spacer(minLength: 0)
                    Button { model.decide(request.id, .passthrough) } label: {
                        Label(session.host.passthroughTitle, systemImage: session.host.placeSymbol)
                            .labelStyle(.iconOnly)
                    }
                    .help("\(session.host.passthroughTitle): ответить там, где работает агент — окошко закроется, откроется его сессия")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill((request.autoReview ? Color.accentColor : Color.orange).opacity(0.09)))
    }

    private var toolTitle: String {
        if tool.hasPrefix("mcp__") { return Adapters.adapter(for: session.kind).summarize(toolName: tool, input: input, cwd: nil) }
        return tool
    }

    /// «Разрешить всегда» — только Claude Code (у хуков Codex такого ответа нет).
    private var ruleOptions: [RuleOption] {
        guard session.kind == .claude, !request.autoReview else { return [] }
        return PermissionRules.options(toolName: tool, input: input, suggestions: request.suggestions)
    }

    private func deny() {
        model.decide(request.id, .deny(reason: reason.isEmpty ? nil : reason))
    }
}

/// Меню «Всегда»: шаблон от HUD (короче список правил) и подсказки самого Claude Code.
struct AlwaysMenu: View {
    let options: [RuleOption]
    let pick: (RuleOption) -> Void

    var body: some View {
        Menu {
            let generated = options.filter(\.generated)
            let suggested = options.filter { !$0.generated }
            if !generated.isEmpty {
                Section("Шаблон") {
                    ForEach(generated) { o in Button("\(o.title) — \(o.scope)") { pick(o) } }
                }
            }
            if !suggested.isEmpty {
                Section("Как предлагает Claude") {
                    ForEach(suggested) { o in Button("\(o.title) — \(o.scope)") { pick(o) } }
                }
            }
        } label: {
            Text("Всегда")
        }
        .fixedSize()
        .help("Разрешить и больше не спрашивать: правило запишется в настройки Claude Code")
    }
}

// MARK: - План (ExitPlanMode)

struct PlanView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest
    let text: String

    @State private var revising = false
    @State private var feedback = ""
    @State private var expanded = false
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(.orange)
                Text("План готов — одобрить?").font(.system(size: 12, weight: .semibold))
                Spacer()
                Countdown(deadline: request.deadline)
            }
            planText
            if revising {
                HStack(spacing: 6) {
                    TextField("Что изменить в плане", text: $feedback)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($feedbackFocused)
                        .onSubmit { revise() }
                    Button("Отправить") { revise() }
                    Button("Отмена") { revising = false }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button { model.decide(request.id, .allowWith(PermissionRules.planApproval(acceptEdits: false))) } label: {
                        Label("Одобрить", systemImage: "checkmark").frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Одобрить план; правки файлов агент будет согласовывать (⌘↩)")
                    Button("Одобрить и править сразу") {
                        model.decide(request.id, .allowWith(PermissionRules.planApproval(acceptEdits: true)))
                    }
                    .help("Одобрить план и до конца сессии принимать правки файлов без вопросов")
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    Button("Доработать…") { revising = true; feedbackFocused = true }
                        .help("Оставить агента в режиме планирования и передать замечания")
                    Spacer()
                    Button { model.decide(request.id, .passthrough) } label: {
                        Label(session.host.passthroughTitle, systemImage: session.host.placeSymbol)
                    }
                    .help("Ответить там, где работает агент: окошко закроется, откроется его сессия")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }

    private var planText: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let limit = expanded ? 400 : 14
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(verbatim: lines.prefix(limit).joined(separator: "\n"))
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: expanded ? 320 : 200)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            if lines.count > 14 {
                Button(expanded ? "Свернуть" : "Показать целиком (\(lines.count) строк)") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }

    private func revise() {
        model.decide(request.id, .deny(reason: feedback.isEmpty ? nil : feedback))
    }
}

struct Countdown: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(deadline.timeIntervalSince(ctx.date)))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(left < 30 ? Color.red : Color.secondary)
                .help("Сколько осталось до того, как вопрос уйдёт в терминал")
        }
    }
}

/// Что именно агент хочет сделать — в читаемом виде.
struct ToolDetail: View {
    let tool: String
    let input: JSONValue
    let cwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch tool {
            case "Bash":
                if let d = input["description"]?.stringValue, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Code(text: input["command"]?.stringValue ?? "", maxLines: 8)
            case "Edit":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                DiffBlock(old: input["old_string"]?.stringValue ?? "", new: input["new_string"]?.stringValue ?? "")
            case "MultiEdit":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                let edits = input["edits"]?.arrayValue ?? []
                Text("Правок: \(edits.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                if let first = edits.first {
                    DiffBlock(old: first["old_string"]?.stringValue ?? "", new: first["new_string"]?.stringValue ?? "")
                }
            case "Write":
                PathLine(path: input["file_path"]?.stringValue ?? "", cwd: cwd)
                Code(text: input["content"]?.stringValue ?? "", maxLines: 8)
            case "WebFetch":
                Code(text: input["url"]?.stringValue ?? "", maxLines: 2)
                if let p = input["prompt"]?.stringValue { Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
            default:
                Code(text: input.pretty(), maxLines: 10)
            }
        }
    }
}

struct PathLine: View {
    let path: String
    let cwd: String

    var body: some View {
        let short = path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
        Label(short, systemImage: "doc")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .lineLimit(1).truncationMode(.middle)
    }
}

/// Код без интерпретации: только текст, никаких ссылок и разметки.
struct Code: View {
    let text: String
    var maxLines: Int = 8
    var color: Color = .primary
    var background: Color = Color.primary.opacity(0.06)

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(maxLines).joined(separator: "\n")
        let more = lines.count - maxLines
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shown)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if more > 0 {
                Text("… ещё \(more) строк").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(background))
    }
}

struct DiffBlock: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !old.isEmpty {
                Code(text: prefixed(old, "−"), maxLines: 5, color: .red, background: Color.red.opacity(0.08))
            }
            Code(text: prefixed(new, "+"), maxLines: 6, color: .green, background: Color.green.opacity(0.08))
        }
    }

    private func prefixed(_ s: String, _ mark: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "\(mark) \($0)" }.joined(separator: "\n")
    }
}

// MARK: - Вопрос

struct QuestionView: View {
    @ObservedObject var model: AppModel
    var host = HostInfo()
    let request: PendingRequest
    let questions: [Question]

    @State private var picked: [Int: Set<Int>] = [:]
    @State private var custom: [Int: String] = [:]
    @FocusState private var focusedCustom: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
                Text(questions.count > 1 ? "Агент задал \(questions.count) вопроса" : "Агент спрашивает")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Countdown(deadline: request.deadline)
            }
            ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let h = q.header, !h.isEmpty {
                            Text(h).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        Text(q.question).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    }
                    if q.multiSelect {
                        Text("Можно выбрать несколько").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                        OptionRow(index: qi == 0 ? oi + 1 : nil, option: opt, multi: q.multiSelect,
                                  selected: picked[qi, default: []].contains(oi)) {
                            toggle(qi, oi, multi: q.multiSelect)
                        }
                    }
                    TextField("Свой ответ", text: Binding(get: { custom[qi] ?? "" }, set: { custom[qi] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .controlSize(.small)
                        .focused($focusedCustom, equals: qi)
                        .onSubmit { if ready { submit() } }
                }
            }
            HStack(spacing: 6) {
                Button { submit() } label: { Label("Ответить", systemImage: "paperplane.fill").frame(minWidth: 90) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!ready)
                    .help("Ответить (⌘↩)")
                Spacer()
                Button { model.decide(request.id, .passthrough) } label: {
                    Label(host.passthroughTitle, systemImage: host.placeSymbol)
                }
                .help("Ответить там, где работает агент: окошко закроется, откроется его сессия")
            }
            .controlSize(.small)
        }
        .background {
            // Цифры 1…9 выбирают вариант первого вопроса, пока не печатаем свой ответ.
            if focusedCustom == nil, let q = questions.first {
                ZStack {
                    ForEach(0..<min(q.options.count, 9), id: \.self) { oi in
                        Button("") { toggle(0, oi, multi: q.multiSelect) }
                            .keyboardShortcut(KeyEquivalent(Character("\(oi + 1)")), modifiers: [])
                    }
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }

    private func toggle(_ qi: Int, _ oi: Int, multi: Bool) {
        var set = picked[qi, default: []]
        if multi {
            if set.contains(oi) { set.remove(oi) } else { set.insert(oi) }
        } else {
            set = [oi]
            custom[qi] = ""
        }
        picked[qi] = set
    }

    private func answer(_ qi: Int) -> String? {
        let c = (custom[qi] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        let q = questions[qi]
        let labels = picked[qi, default: []].sorted().compactMap { q.options.indices.contains($0) ? q.options[$0].label : nil }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private var ready: Bool { questions.indices.allSatisfy { answer($0) != nil } }

    private func submit() {
        var result: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            guard let a = answer(i) else { return }
            result[q.question] = a
        }
        model.decide(request.id, .answer(result))
    }
}

struct OptionRow: View {
    let index: Int?
    let option: QuestionOption
    let multi: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if let index { Text("\(index)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.12) : (hover ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Просрочено

struct ExpiredView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    let request: PendingRequest

    var body: some View {
        let what: String = {
            switch request.kind {
            case .permission(let t, _): return "Запрос разрешения (\(t))"
            case .question: return "Вопрос агента"
            case .plan: return "План на одобрение"
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color(red: 0.75, green: 0.5, blue: 0.25))
                Text("Просрочено").font(.system(size: 12, weight: .semibold))
            }
            Text("\(what) ждал слишком долго и ушёл в \(session.host.placeTo). Ответь там.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.open(session.id) } label: {
                    Label(session.host.openTitle, systemImage: "arrow.up.forward.app")
                }
                    .buttonStyle(.borderedProminent)
                Button("Убрать") { model.dismissExpired(session.id) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.brown.opacity(0.1)))
    }
}
