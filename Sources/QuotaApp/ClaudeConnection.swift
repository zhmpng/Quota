import Foundation
import Security
import LocalAuthentication
import Network
import QuotaCore

enum QuotaKeychain {
    static let service="local.quota.claude.web-session"
    static func read(service:String, allowPrompt:Bool) throws -> Data? {
        var query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
                               kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        let context=LAContext();context.interactionNotAllowed = !allowPrompt
        query[kSecUseAuthenticationContext as String]=context
        var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status == errSecItemNotFound{return nil}
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw QuotaError.authentication(service == "Claude Safe Storage" ? "macOS требует разрешение на чтение сессии Claude Desktop. Нажмите «Сеанс Claude Desktop» и разрешите доступ к Связке ключей." : "Связка ключей не разрешила чтение. Нажмите «Сеанс Claude Code» или войдите через Claude.")
        }
        guard status == errSecSuccess else{throw QuotaError.message("Связка ключей недоступна (код \(status)).")}
        return item as? Data
    }
    static func saveWebSession(_ value:String) throws {
        guard !value.isEmpty,!value.contains(where:{";\r\n".contains($0)}) else{throw QuotaError.message("Некорректный формат сессии Claude.")}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"claude"]
        let attributes:[String:Any]=[kSecValueData as String:Data(value.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update=SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert=query;attributes.forEach {insert[$0]=$1}
            guard SecItemAdd(insert as CFDictionary,nil) == errSecSuccess else{throw QuotaError.message("Не удалось сохранить подключение Claude в Связке ключей.")}
        } else if update != errSecSuccess {throw QuotaError.message("Не удалось обновить подключение Claude.")}
    }
    static func removeWebSession() {SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service] as CFDictionary)}
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}

struct ProviderHTTP {
    static let delegate=NoRedirect()
    static func session(proxy:LocalProxy?) -> URLSession {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=25;config.timeoutIntervalForResource=30
        config.httpCookieStorage=nil;config.httpShouldSetCookies=false
        if let proxy {config.proxyConfigurations=[proxy.configuration]}
        return URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
    }
    static func get(_ url:URL,headers:[String:String],proxy:LocalProxy?=nil) async throws -> Any {
        guard url.scheme == "https",["api.anthropic.com","claude.ai"].contains(url.host ?? "") else{throw QuotaError.message("Недопустимый адрес сервиса.")}
        var request=URLRequest(url:url);request.httpMethod="GET"
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("Quota/1.0 (macOS; subscription usage reader)",forHTTPHeaderField:"User-Agent")
        headers.forEach {request.setValue($1,forHTTPHeaderField:$0)}
        let connection=session(proxy:proxy)
        defer {connection.finishTasksAndInvalidate()}
        let data:Data,response:URLResponse
        do {(data,response)=try await connection.data(for:request)}
        catch {
            if let proxy {throw QuotaError.message("Нет связи через ATLAS (127.0.0.1:\(proxy.port)). Откройте Claude через ярлык выбранного профиля и повторите обновление.")}
            throw QuotaError.message("Не удалось связаться с Claude. Проверьте интернет-подключение.")
        }
        guard let http=response as? HTTPURLResponse else{throw QuotaError.message("Сервис не вернул HTTP-ответ.")}
        if http.statusCode == 401 {throw QuotaError.authentication("Сессия Claude закончилась. Войдите снова.")}
        if http.statusCode == 429 {
            let raw=http.value(forHTTPHeaderField:"Retry-After")
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="EEE, dd MMM yyyy HH:mm:ss z"
            let date=raw.flatMap {Double($0).map {Date().addingTimeInterval(max(60,$0))} ?? f.date(from:$0)}
            throw QuotaError.rateLimited(date ?? Date().addingTimeInterval(600))
        }
        guard http.statusCode == 200 else {
            throw QuotaError.message(http.statusCode == 403 ? "Claude не разрешил чтение через это подключение. Попробуйте вход через страницу Claude." : "Claude: ответ HTTP \(http.statusCode).")
        }
        guard data.count<8_000_000 else{throw QuotaError.message("Ответ Claude превышает допустимый размер.")}
        do {return try JSONSerialization.jsonObject(with:data)}catch{throw QuotaError.message("Claude вернул страницу вместо данных. Завершите вход в окне подключения.")}
    }
}

struct ClaudeOrganization:Identifiable {let id:String;let name:String}
struct ClaudeLocalCredentials {let accessToken:String;let plan:String?}

enum ClaudeConnection {
    static func localCredentials(allowPrompt:Bool) throws -> ClaudeLocalCredentials {
        let home=FileManager.default.homeDirectoryForCurrentUser
        let configured=ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {URL(fileURLWithPath:$0)}
        let paths=[configured?.appendingPathComponent(".credentials.json"),home.appendingPathComponent(".claude/.credentials.json")].compactMap {$0}
        var data:Data?
        for path in paths where FileManager.default.fileExists(atPath:path.path) {
            if let size=(try? path.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<1_000_000 {data=try? Data(contentsOf:path);if data != nil{break}}
        }
        if data == nil {data=try QuotaKeychain.read(service:"Claude Code-credentials",allowPrompt:allowPrompt)}
        guard let data,let root=try? JSONValue.object(data),let oauth=root["claudeAiOauth"] as? [String:Any],
              let token=oauth["accessToken"] as? String,!token.isEmpty else {
            throw QuotaError.authentication("Не найден активный сеанс Claude Code. Подключите Claude через страницу входа.")
        }
        if let scopes=oauth["scopes"] as? [String],!scopes.contains("user:profile") {throw QuotaError.authentication("Сеанс Claude Code не разрешает чтение профиля. Используйте вход через Claude.")}
        if let expiration=JSONValue.number(oauth["expiresAt"]),Date(timeIntervalSince1970:expiration/1000)<=Date() {
            throw QuotaError.authentication("Сеанс Claude Code истёк. Откройте Claude Code для обновления или войдите через Claude.")
        }
        return .init(accessToken:token,plan:oauth["subscriptionType"] as? String)
    }
    static func fetchLocal(allowPrompt:Bool,proxy:LocalProxy?=nil) async throws -> ProviderSnapshot {
        let credentials=try localCredentials(allowPrompt:allowPrompt)
        let headers=["Authorization":"Bearer \(credentials.accessToken)","anthropic-beta":"oauth-2025-04-20"]
        guard let usage=try await ProviderHTTP.get(URL(string:"https://api.anthropic.com/api/oauth/usage")!,headers:headers,proxy:proxy) as? [String:Any] else{throw QuotaError.message("Неподдерживаемый ответ Claude.")}
        let profile=(try? await ProviderHTTP.get(URL(string:"https://api.anthropic.com/api/oauth/profile")!,headers:headers,proxy:proxy)) as? [String:Any] ?? [:]
        return ClaudeParser.parse(usage:usage,profile:profile,plan:credentials.plan,source:"Сеанс Claude Code")
    }
    static func webSession() throws -> String? {
        guard let data=try QuotaKeychain.read(service:QuotaKeychain.service,allowPrompt:false) else{return nil}
        return String(data:data,encoding:.utf8)
    }
    static func organizations(session:String,proxy:LocalProxy?=nil) async throws -> [ClaudeOrganization] {
        guard DesktopCookies.validSession(session) else {throw QuotaError.authentication("Некорректная сессия Claude.")}
        guard let list=try await ProviderHTTP.get(URL(string:"https://claude.ai/api/organizations")!,headers:["Cookie":"sessionKey=\(session)"],proxy:proxy) as? [[String:Any]] else{throw QuotaError.message("Не удалось прочитать организации Claude.")}
        return list.compactMap { item in
            guard let id=item["uuid"] as? String,UUID(uuidString:id) != nil else{return nil}
            return .init(id:id,name:item["name"] as? String ?? "Личный аккаунт")
        }
    }
    static func fetchWeb(session:String, organization:ClaudeOrganization,proxy:LocalProxy?=nil,source:String?=nil) async throws -> ProviderSnapshot {
        guard DesktopCookies.validSession(session) else {throw QuotaError.authentication("Некорректная сессия Claude.")}
        guard UUID(uuidString:organization.id) != nil else{throw QuotaError.message("Неверный идентификатор организации.")}
        let headers=["Cookie":"sessionKey=\(session)"],base="https://claude.ai/api/organizations/\(organization.id)"
        guard let usage=try await ProviderHTTP.get(URL(string:base+"/usage")!,headers:headers,proxy:proxy) as? [String:Any] else{throw QuotaError.message("Claude не передал лимиты.")}
        async let extraRead=try? ProviderHTTP.get(URL(string:base+"/overage_spend_limit")!,headers:headers,proxy:proxy)
        async let prepaidRead=try? ProviderHTTP.get(URL(string:base+"/prepaid/credits")!,headers:headers,proxy:proxy)
        async let profileRead=try? ProviderHTTP.get(URL(string:"https://claude.ai/api/account")!,headers:headers,proxy:proxy)
        let extra=await extraRead as? [String:Any],prepaid=await prepaidRead as? [String:Any],profile=await profileRead as? [String:Any] ?? [:]
        return ClaudeParser.parse(usage:usage,profile:profile,extra:extra,prepaid:prepaid,source:source ?? "Claude · \(organization.name)")
    }
}
