import Foundation

/// Какой агент прислал событие. Новый агент = новый случай + адаптер.
public enum AgentKind: String, Sendable, CaseIterable {
    case claude
    case codex
    // позже: pi

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Файл, куда ставятся хуки этого агента.
    public var hooksFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }
}

public enum AgentState: String, Sendable {
    case starting, working, waitingPermission, waitingAnswer, expired, idle, done, error, ended

    public var needsUser: Bool { self == .waitingPermission || self == .waitingAnswer }
}

/// Где запущен агент: нужно для кнопки «Открыть».
public struct HostInfo: Equatable, Sendable {
    public var termProgram: String?
    public var tty: String?            // "/dev/ttys003"
    public var agentPid: Int32?
    public var herdrPaneId: String?
    public var herdrSocket: String?
    public var processChain: [String]  // имена процессов от агента вверх
    public var appBundleId: String?    // GUI-приложение, внутри которого идёт сессия
    public var appName: String?
    public var hostSessionId: String?  // id сессии в приложении (Claude: local_…)

    public static let claudeDesktop = "com.anthropic.claudefordesktop"
    public static let codexDesktop = "com.openai.codex"
    public static let desktopApps: Set<String> = [claudeDesktop, codexDesktop]

    public init(termProgram: String? = nil, tty: String? = nil, agentPid: Int32? = nil,
                herdrPaneId: String? = nil, herdrSocket: String? = nil, processChain: [String] = [],
                appBundleId: String? = nil, appName: String? = nil, hostSessionId: String? = nil) {
        self.termProgram = termProgram
        self.tty = tty
        self.agentPid = agentPid
        self.herdrPaneId = herdrPaneId
        self.herdrSocket = herdrSocket
        self.processChain = processChain
        self.appBundleId = appBundleId
        self.appName = appName
        self.hostSessionId = hostSessionId
    }

    public var isEmpty: Bool { tty == nil && agentPid == nil && herdrPaneId == nil && termProgram == nil && appBundleId == nil }

    /// Сессия идёт в десктопном приложении (Claude, Codex), а не в терминале.
    public var isDesktopApp: Bool { tty == nil && appBundleId.map(Self.desktopApps.contains) == true }

    /// Человекочитаемое имя хоста: «Terminal», «herdr», «приложение Claude».
    public var label: String {
        if isDesktopApp {
            switch appBundleId {
            case Self.claudeDesktop: return "приложение Claude"
            case Self.codexDesktop: return "приложение Codex"
            default: return appName ?? "приложение"
            }
        }
        if herdrPaneId != nil { return "herdr" }
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case let p?: return p
        case nil: return "Терминал"
        }
    }

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        if let v = termProgram { o["term_program"] = .string(v) }
        if let v = tty { o["tty"] = .string(v) }
        if let v = agentPid { o["agent_pid"] = .int(Int(v)) }
        if let v = herdrPaneId { o["herdr_pane_id"] = .string(v) }
        if let v = herdrSocket { o["herdr_socket"] = .string(v) }
        o["process_chain"] = .array(processChain.map { .string($0) })
        if let v = appBundleId { o["app_bundle_id"] = .string(v) }
        if let v = appName { o["app_name"] = .string(v) }
        if let v = hostSessionId { o["host_session_id"] = .string(v) }
        return .object(o)
    }

    public init(json: JSONValue?) {
        self.init(
            termProgram: json?["term_program"]?.stringValue,
            tty: json?["tty"]?.stringValue,
            agentPid: json?["agent_pid"]?.intValue.map { Int32($0) },
            herdrPaneId: json?["herdr_pane_id"]?.stringValue,
            herdrSocket: json?["herdr_socket"]?.stringValue,
            processChain: json?["process_chain"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            appBundleId: json?["app_bundle_id"]?.stringValue,
            appName: json?["app_name"]?.stringValue,
            hostSessionId: json?["host_session_id"]?.stringValue
        )
    }
}

public enum StepStatus: String, Sendable { case running, ok, failed }

public struct Step: Identifiable, Equatable, Sendable {
    public let id: String
    public var toolName: String
    public var summary: String
    public var startedAt: Date
    public var durationMs: Int?
    public var status: StepStatus
    public var agentId: String?      // шаг внутри субагента
    public var isSubagent: Bool      // сам шаг — запуск субагента
    var inputFingerprint: String     // чтобы сопоставить PostToolUse без tool_use_id

    public init(id: String, toolName: String, summary: String, startedAt: Date, durationMs: Int? = nil,
                status: StepStatus = .running, agentId: String? = nil, isSubagent: Bool = false,
                inputFingerprint: String = "") {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.status = status
        self.agentId = agentId
        self.isSubagent = isSubagent
        self.inputFingerprint = inputFingerprint
    }
}

public struct QuestionOption: Equatable, Sendable {
    public var label: String
    public var description: String?
}

public struct Question: Equatable, Sendable {
    public var question: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool
}

public enum PendingKind: Equatable, Sendable {
    case permission(toolName: String, toolInput: JSONValue)
    case question([Question], rawInput: JSONValue)

    public var isQuestion: Bool { if case .question = self { return true } else { return false } }
}

public enum PendingStatus: String, Sendable {
    case open                 // ждём пользователя
    case answered             // ответили в HUD
    case answeredElsewhere    // ответили в терминале
    case expired              // время хука вышло
}

public struct PendingRequest: Identifiable, Equatable, Sendable {
    public let id: String          // request_id
    public var kind: PendingKind
    public var createdAt: Date
    public var deadline: Date
    public var status: PendingStatus
    var inputFingerprint: String
}

/// Ответ пользователя, общий для всех агентов. Адаптер переводит его в формат своего агента.
public enum Decision: Equatable, Sendable {
    case allow
    case deny(reason: String?)
    case answer([String: String])  // текст вопроса → выбранные метки через ", " или свой текст
    case passthrough               // «ответить в терминале» / нет ответа

    public var logLabel: String {
        switch self {
        case .allow: return "разрешено"
        case .deny: return "отклонено"
        case .answer: return "ответ"
        case .passthrough: return "в терминал"
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String              // "<kind>:<session_id>"
    public let kind: AgentKind
    public let sessionId: String
    public var cwd: String
    public var title: String
    public var host: HostInfo
    public var baseState: AgentState
    public var steps: [Step]
    public var pending: [PendingRequest]
    public var startedAt: Date
    public var lastEventAt: Date
    public var finishedAt: Date?
    public var lastMessage: String?
    public var model: String?
    public var transcriptPath: String?
    public var hidden: Bool
    /// Показывать ли сессию. Тред Codex показываем только после первого промпта:
    /// приложение Codex открывает и служебные треды, их не должно быть видно даже на миг.
    public var revealed = true
    /// Агент спросил пользователя в самом приложении (Codex `request_user_input`) — текст вопроса.
    public var waitingNote: String?
    var askedUserThisTurn = false

    public static let maxSteps = 200

    public init(kind: AgentKind, sessionId: String, cwd: String, now: Date) {
        self.id = "\(kind.rawValue):\(sessionId)"
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = ""
        self.host = HostInfo()
        self.baseState = .starting
        self.steps = []
        self.pending = []
        self.startedAt = now
        self.lastEventAt = now
        self.lastMessage = nil
        self.hidden = false
    }

    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Первый открытый запрос — его и показываем.
    public var activePending: PendingRequest? { pending.first(where: { $0.status == .open }) }
    public var expiredPending: PendingRequest? { pending.first(where: { $0.status == .expired }) }

    public var state: AgentState {
        if let p = activePending { return p.kind.isQuestion ? .waitingAnswer : .waitingPermission }
        if expiredPending != nil { return .expired }
        return baseState
    }

    public var currentStep: Step? { steps.last(where: { $0.status == .running }) }

    /// Стабильное «зерно» внешнего вида персонажа.
    public var avatarSeed: UInt64 { stableHash(id) }
}

/// FNV-1a: стабильный между запусками хэш (у `Hasher` случайная соль).
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}
