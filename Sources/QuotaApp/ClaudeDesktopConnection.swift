import Foundation
import QuotaCore

enum ClaudeDesktopConnection {
    static func session(profile:DesktopProfile, allowPrompt:Bool) throws -> String {
        _ = try profile.validatedProxy()
        let databases=DesktopCookies.databases(in:profile.directory)
        guard !databases.isEmpty else {
            throw QuotaError.authentication("В выбранном профиле нет сессии Claude Desktop. Откройте его через свой ярлык и войдите в аккаунт.")
        }
        var cookies:[DesktopCookies.Cookie]=[]
        var readFailure:Error?
        for file in databases {
            do {cookies += try DesktopCookies.read(from:file)} catch {readFailure=error}
        }
        guard !cookies.isEmpty else {
            if let readFailure {throw readFailure}
            throw QuotaError.authentication("В выбранном профиле Claude Desktop нет действующей сессии. Откройте этот профиль и войдите в Claude.")
        }
        // Never save this cookie in Quota: re-read the selected profile on every refresh,
        // so logout, session rotation and account switching propagate automatically.
        let ordered=cookies.sorted {$0.updated > $1.updated}
        var password:Data?
        var keyRead=false
        var lastFailure:Error?
        for cookie in ordered {
            if !cookie.encrypted.isEmpty,!keyRead {
                password=try QuotaKeychain.read(service:"Claude Safe Storage",allowPrompt:allowPrompt);keyRead=true
            }
            do {return try DesktopCookies.decrypt(cookie,password:password)} catch {lastFailure=error}
        }
        throw lastFailure ?? QuotaError.authentication("Не удалось прочитать сессию Claude Desktop.")
    }
}
