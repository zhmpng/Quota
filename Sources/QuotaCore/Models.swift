import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, openai
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "ChatGPT / Codex" }
}

public enum ConnectionState: String, Codable, Sendable {
    case disconnected, ready, loading, reauth, unavailable, offline, rateLimited
}

public struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var compactTitle: String
    public var bucket: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?
    public var isShared: Bool
    public init(id: String, title: String, compactTitle: String, bucket: String, usedPercent: Double,
                resetsAt: Date? = nil, durationMinutes: Int? = nil, isShared: Bool = false) {
        self.id=id; self.title=title; self.compactTitle=compactTitle; self.bucket=bucket
        self.usedPercent=usedPercent; self.resetsAt=resetsAt; self.durationMinutes=durationMinutes; self.isShared=isShared
    }
    public var remaining: Double { max(0, min(100, 100-usedPercent)) }
    public func isPendingReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

public struct AccountMetric: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var explanation: String?
    public init(_ id: String, _ title: String, _ value: String, explanation: String? = nil) {
        self.id=id; self.title=title; self.value=value; self.explanation=explanation
    }
}

public struct MoneyMetric: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var amount: Double
    public var currency: String
    public var period: String
    public init(id: String, title: String, amount: Double, currency: String, period: String) {
        self.id=id; self.title=title; self.amount=amount; self.currency=currency; self.period=period
    }
    public var formatted: String { amount.formatted(.currency(code: currency)) }
}

public struct DailyActivity: Codable, Identifiable, Equatable, Sendable {
    public var day: String
    public var tokens: Double
    public var id: String { day }
    public init(day: String, tokens: Double) { self.day=day; self.tokens=tokens }
}

public struct ProviderSnapshot: Codable, Identifiable, Sendable {
    public var provider: Provider
    public var id: Provider { provider }
    public var state: ConnectionState
    public var plan: String?
    public var accountLabel: String?
    public var source: String
    public var observedAt: Date?
    public var lastAttemptAt: Date?
    public var retryAfter: Date?
    public var windows: [QuotaWindow]
    public var metrics: [AccountMetric]
    public var money: [MoneyMetric]
    public var activity: [DailyActivity]
    public var selectedWindowID: String?
    public var message: String?
    public var isDemo: Bool

    public init(provider: Provider, state: ConnectionState = .disconnected, plan: String? = nil,
                accountLabel: String? = nil, source: String = "", observedAt: Date? = nil,
                windows: [QuotaWindow] = [], metrics: [AccountMetric] = [], money: [MoneyMetric] = [],
                activity: [DailyActivity] = [], message: String? = nil, isDemo: Bool = false) {
        self.provider=provider; self.state=state; self.plan=plan; self.accountLabel=accountLabel
        self.source=source; self.observedAt=observedAt; self.lastAttemptAt=observedAt
        self.retryAfter=nil; self.windows=windows; self.metrics=metrics; self.money=money
        self.activity=activity; self.message=message; self.selectedWindowID=nil; self.isDemo=isDemo
    }

    public var selectedWindow: QuotaWindow? {
        let chosen = windows.first(where: {$0.id == selectedWindowID}) ?? windows.first
        // Only an explicitly shared exhausted quota for the same bucket supersedes selection.
        return windows.first(where: {$0.isShared && $0.bucket == chosen?.bucket && $0.remaining == 0}) ?? chosen
    }
    public var widgetName: String {
        if provider == .claude { return "Claude" }
        let bucket = selectedWindow?.bucket.lowercased() ?? "codex"
        return bucket.contains("codex") ? "Codex" : "ChatGPT"
    }
    public func stale(at now: Date) -> Bool {
        guard let observedAt else { return false }
        return now.timeIntervalSince(observedAt) > 3600 || state == .offline || state == .rateLimited
    }
    public func visibleRemaining(at now: Date) -> Double? {
        guard ![.disconnected,.reauth,.unavailable].contains(state), let window=selectedWindow,
              !window.isPendingReset(at: now) else { return nil }
        return window.remaining
    }
    public func status(at now: Date, compact: Bool = false) -> String {
        switch state {
        case .disconnected: return "Подключить"
        case .reauth: return "Войти снова"
        case .unavailable: return "Нет данных"
        case .loading where windows.isEmpty: return "Загрузка"
        case .rateLimited: return "Пауза обновлений"
        case .offline: return windows.isEmpty ? "Нет данных" : "Нет связи"
        default: break
        }
        guard let window=selectedWindow else { return "Нет данных" }
        if window.isPendingReset(at: now) { return "Проверяем сброс" }
        if stale(at: now) { return "Данные устарели" }
        if window.remaining == 0 { return compact ? "Лимит" : "Лимит исчерпан" }
        if window.remaining <= 20 { return compact ? "Мало" : "Мало осталось" }
        return compact ? window.compactTitle : window.title
    }
    public func redactedForWidget() -> Self {
        var copy=self; copy.accountLabel=nil; copy.money=[]; copy.metrics=[]; copy.activity=[]
        copy.message=nil; copy.source=""; return copy
    }
}

public struct DashboardSnapshot: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var providers: [ProviderSnapshot]
    public init(providers: [ProviderSnapshot] = Provider.allCases.map {ProviderSnapshot(provider:$0)}) { self.providers=providers }
    public func snapshot(_ provider: Provider) -> ProviderSnapshot { providers.first(where: {$0.provider == provider}) ?? .init(provider:provider) }
    public mutating func replace(_ snapshot: ProviderSnapshot) { providers.removeAll {$0.provider == snapshot.provider}; providers.append(snapshot); providers.sort {$0.provider.rawValue < $1.provider.rawValue} }
}

public enum QuotaFormatting {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return "—" }
        return value > 0 && value < 1 ? "<1" : String(Int(floor(value)))
    }
    public static func reset(_ date: Date?, now: Date, compact: Bool) -> String {
        guard let date else { return compact ? "Сброс —" : "Сброс неизвестен" }
        guard date > now else { return compact ? "" : "Ждём подтверждения" }
        let cal=Calendar.current
        if cal.isDate(date, inSameDayAs:now) { return (compact ? "до " : "Сброс в ") + date.formatted(date:.omitted,time:.shortened) }
        if let tomorrow=cal.date(byAdding:.day,value:1,to:now),cal.isDate(date,inSameDayAs:tomorrow) { return compact ? "завтра" : "Завтра, " + date.formatted(date:.omitted,time:.shortened) }
        let f=DateFormatter();f.dateFormat=compact ? "dd.MM" : "dd.MM, HH:mm";return f.string(from:date)
    }
}

public enum QuotaError: LocalizedError {
    case message(String)
    case authentication(String)
    case rateLimited(Date?)
    public var errorDescription: String? {
        switch self { case .message(let text),.authentication(let text): return text
        case .rateLimited: return "Сервис ограничил частоту запросов. Обновление возобновится после паузы." }
    }
}
