import Foundation
import CoreFoundation

public enum JSONValue {
    public static func number(_ raw: Any?) -> Double? {
        if let n=raw as? NSNumber { guard CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil}; return n.doubleValue }
        if let s=raw as? String,let n=Double(s),n.isFinite { return n }; return nil
    }
    public static func date(_ raw: Any?) -> Date? {
        if let n=number(raw),n > 0 { return Date(timeIntervalSince1970:n) }
        guard let s=raw as? String else{return nil}
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return f.date(from:s) ?? ISO8601DateFormatter().date(from:s)
    }
    public static func object(_ data: Data) throws -> [String:Any] {
        guard let o=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw QuotaError.message("Неожиданный формат ответа сервиса.")}; return o
    }
    public static func nonnegative(_ raw: Any?) -> Double? { guard let n=number(raw),n>=0 else{return nil};return n }
}

public enum CodexParser {
    public static func parse(account: [String:Any], limits: [String:Any], usage: [String:Any]?, now: Date = Date()) -> ProviderSnapshot {
        let a=account["account"] as? [String:Any] ?? [:]
        var result=ProviderSnapshot(provider:.openai,state:.ready,plan:a["planType"] as? String,
                                    accountLabel:a["email"] as? String,source:"Codex App Server",observedAt:now)
        var buckets=limits["rateLimitsByLimitId"] as? [String:[String:Any]] ?? [:]
        if buckets.isEmpty,let legacy=limits["rateLimits"] as? [String:Any] { buckets[legacy["limitId"] as? String ?? "codex"]=legacy }
        for key in buckets.keys.sorted(by: {a,b in a == "codex" ? b != "codex" : (b == "codex" ? false : a < b)}) {
            guard let bucket=buckets[key] else{continue}
            let bucketName=bucket["limitName"] as? String
            if result.plan == nil { result.plan=bucket["planType"] as? String }
            for name in ["primary","secondary"] {
                guard let w=bucket[name] as? [String:Any],let used=JSONValue.number(w["usedPercent"]),used>=0,used<=100 else{continue}
                let duration=JSONValue.number(w["windowDurationMins"]).flatMap {$0>=0 && $0<Double(Int.max) ? Int($0) : nil}
                let label=windowLabel(duration, fallback:name == "primary" ? "Основной лимит" : "Доп. лимит")
                result.windows.append(.init(id:key+"-"+name,title:key == "codex" ? label : (bucketName ?? key)+" · "+label,
                    compactTitle:duration == 10080 ? "Неделя" : duration == 300 ? "Сессия" : label,
                    bucket:key,usedPercent:used,resetsAt:JSONValue.date(w["resetsAt"]),durationMinutes:duration,isShared:true))
            }
            if let credits=bucket["credits"] as? [String:Any] {
                if credits["unlimited"] as? Bool == true {result.metrics.append(.init(key+"-credits","Кредиты · "+key,"Без ограничения"))}
                else if let balance=credits["balance"], !(balance is NSNull) {
                    result.metrics.append(.init(key+"-credits","Остаток кредитов · "+key,String(describing:balance),explanation:"Кредиты сервиса. Это не денежная сумма."))
                }
            }
        }
        if let resets=limits["rateLimitResetCredits"] as? [String:Any],let count=JSONValue.nonnegative(resets["availableCount"]) {
            result.metrics.append(.init("reset-credits","Доступные сбросы",count.formatted(.number.precision(.fractionLength(0)))))
        }
        if let allowed=limits["ordinaryUsageAllowed"] as? Bool {result.metrics.append(.init("ordinary-usage","Использование по подписке",allowed ? "Доступно" : "Ограничено сервисом"))}
        if let s=usage?["summary"] as? [String:Any] {
            for (key,label) in [("lifetimeTokens","Токены за всё время"),("peakDailyTokens","Пик токенов за день"),("currentStreakDays","Дней подряд"),("longestStreakDays","Самая длинная серия, дней"),("longestRunningTurnSec","Самая длинная задача, секунд")] {
                if let value=JSONValue.nonnegative(s[key]) {result.metrics.append(.init(key,label,value.formatted(.number.precision(.fractionLength(0)))))}
            }
        }
        if let days=usage?["dailyUsageBuckets"] as? [[String:Any]] {
            result.activity=days.compactMap { d in guard let day=d["startDate"] as? String,let tokens=JSONValue.nonnegative(d["tokens"]) else{return nil}; return .init(day:day,tokens:tokens) }.sorted {$0.day<$1.day}
        }
        if result.windows.isEmpty { result.state = .unavailable; result.message="Сервис не вернул числовые лимиты для этого аккаунта." }
        return result
    }
    private static func windowLabel(_ duration: Int?, fallback: String) -> String {
        guard let duration else{return fallback}
        if duration == 10080{return "Неделя"}; if duration == 1440{return "Сутки"}
        if duration>0 && duration%60 == 0{return "Сессия · \(duration/60) ч"}
        return "Окно · \(duration) мин"
    }
}

public enum ClaudeParser {
    public static func parse(usage: [String:Any], profile: [String:Any] = [:], extra: [String:Any]? = nil,
                             prepaid: [String:Any]? = nil, plan: String? = nil, source: String,
                             now: Date = Date()) -> ProviderSnapshot {
        let account=profile["account"] as? [String:Any] ?? profile
        let organization=profile["organization"] as? [String:Any] ?? [:]
        var result=ProviderSnapshot(provider:.claude,state:.ready,plan:plan ?? organization["subscription_type"] as? String,
            accountLabel:(account["email_address"] ?? account["email"]) as? String,source:source,observedAt:now)
        let definitions:[(String,String,String,Int,Bool)] = [
            ("five_hour","Сессия · 5 ч","Сессия",300,true), ("seven_day","Все модели · неделя","Неделя",10080,true),
            ("seven_day_opus","Opus · неделя","Opus",10080,false), ("seven_day_sonnet","Sonnet · неделя","Sonnet",10080,false),
            ("seven_day_oauth_apps","Приложения · неделя","Приложения",10080,false), ("seven_day_cowork","Cowork · неделя","Cowork",10080,false),
            ("seven_day_routines","Routines · неделя","Routines",10080,false)
        ]
        for (key,title,compact,duration,shared) in definitions {
            guard let w=usage[key] as? [String:Any],let used=JSONValue.number(w["utilization"]),used>=0,used<=100 else{continue}
            result.windows.append(.init(id:key,title:title,compactTitle:compact,bucket:"claude",usedPercent:used,
                                       resetsAt:JSONValue.date(w["resets_at"]),durationMinutes:duration,isShared:shared))
        }
        if let entries=usage["limits"] as? [[String:Any]] {
            for (index,w) in entries.enumerated() {
                guard w["is_active"] as? Bool != false,let used=JSONValue.number(w["percent"]),used>=0,used<=100 else{continue}
                let scope=w["scope"] as? [String:Any] ?? [:], model=scope["model"] as? [String:Any] ?? [:]
                let name=model["display_name"] as? String ?? w["kind"] as? String ?? "Лимит \(index+1)"
                result.windows.append(.init(id:"scoped-\(model["id"] as? String ?? String(index))",title:name,compactTitle:name,
                    bucket:"claude",usedPercent:used,resetsAt:JSONValue.date(w["resets_at"]),isShared:false))
            }
        }
        let overage=extra ?? usage["extra_usage"] as? [String:Any]
        if let overage {
            let enabled=overage["is_enabled"] as? Bool
            if let enabled {result.metrics.append(.init("extra-enabled","Дополнительное использование",enabled ? "Включено" : "Выключено"))}
            if enabled != false {
                let currency=(overage["currency"] as? String)?.uppercased()
                for (key,title) in [("used_credits","Потрачено сверх подписки"),("monthly_credit_limit","Месячный лимит доп. расходов")] {
                    let raw=overage[key] ?? (key == "monthly_credit_limit" ? overage["monthly_limit"] : nil)
                    guard let value=JSONValue.nonnegative(raw) else{continue}
                    if let currency,currency.count == 3 {
                        result.money.append(.init(id:key,title:title,amount:value/100,currency:currency,period:"Текущий месяц"))
                    } else {
                        result.metrics.append(.init(key,title,value.formatted(),explanation:"Единицы источника; валюта не передана. В деньги не пересчитываем."))
                    }
                }
            }
        }
        if let prepaid,let amount=JSONValue.nonnegative(prepaid["amount"]),let currency=prepaid["currency"] as? String,currency.count == 3 {
            result.money.append(.init(id:"prepaid",title:"Баланс доп. использования",amount:amount/100,currency:currency.uppercased(),period:"Текущий баланс"))
        }
        if result.windows.isEmpty {result.state = .unavailable;result.message="Аккаунт доступен, но сервис не передал числовые лимиты."}
        return result
    }
}
