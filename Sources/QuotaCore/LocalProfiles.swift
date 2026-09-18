import Foundation
import Network

/// Only the loopback HTTP CONNECT relay is reused. Upstream passwords are never imported.
public struct LocalProxy: Equatable, Sendable {
    public let port: UInt16
    public init?(port: Int) {
        guard (1...65535).contains(port) else { return nil }
        self.port = UInt16(port)
    }
    public var url: String { "http://127.0.0.1:\(port)" }
    public var configuration: ProxyConfiguration {
        var value = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        value.allowFailover = false
        return value
    }
    public func environment(inheriting original: [String:String]) -> [String:String] {
        var env = original
        // Override both casings: reqwest/curl can prefer lowercase variables.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[key] = url }
        for key in ["NO_PROXY", "no_proxy"] { env[key] = "127.0.0.1,localhost,::1" }
        return env
    }
}

public struct DesktopProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let directory: URL
    public let proxy: LocalProxy?
    public let configurationError: String?
    public var isAtlas: Bool { id.hasPrefix("atlas-") }
    public init(id: String, title: String, directory: URL, proxy: LocalProxy?, configurationError: String? = nil) {
        self.id=id; self.title=title; self.directory=directory; self.proxy=proxy; self.configurationError=configurationError
    }
    public func validatedProxy() throws -> LocalProxy? {
        if let configurationError { throw QuotaError.message(configurationError) }
        return proxy
    }
}

public enum LocalProfiles {
    /// Parse the literal assignments written by ATLAS's sq() function, never source shell code.
    /// Ignore all upstream settings; do not retain their values in the returned dictionary.
    public static func parse(_ text: String) -> [String:String] {
        let allowed: Set<String> = ["LOCAL_PORT", "PROFILE_NUM", "PROFILE_DATA_DIR", "PROFILE_IMYA"]
        var result: [String:String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line=rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equal=line.firstIndex(of: "=") else { continue }
            let key=String(line[..<equal])
            guard allowed.contains(key) else { continue }
            let raw=String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("'"), raw.hasSuffix("'") {
                let inner=String(raw.dropFirst().dropLast())
                // ATLAS encodes an apostrophe as '\''; no other shell syntax is accepted.
                let pieces=inner.components(separatedBy: "'\\''")
                guard !pieces.contains(where: { $0.contains("'") }) else { continue }
                result[key]=pieces.joined(separator: "'")
            } else if !raw.isEmpty, raw.allSatisfy({ $0.isNumber }) { result[key]=raw }
        }
        return result
    }
    private static func read(_ url: URL) throws -> [String:String] {
        guard let size=(try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 128_000,
              let text=try? String(contentsOf: url, encoding: .utf8) else {
            throw QuotaError.message("Не удалось прочитать настройки ATLAS. Откройте приложение через его ярлык и повторите обновление.")
        }
        return parse(text)
    }
    public static func codexProxy(mode: String = "auto", home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> LocalProxy? {
        if mode == "direct" { return nil }
        let file=home.appendingPathComponent(".config/atlas-chatgpt-proxy/proxy.conf")
        guard FileManager.default.fileExists(atPath: file.path) else {
            if mode == "atlas" { throw QuotaError.message("Настройки ChatGPT Proxy (ATLAS) не найдены. Сначала запустите его ярлык.") }
            return nil
        }
        let values=try read(file)
        guard let number=values["LOCAL_PORT"].flatMap(Int.init), let proxy=LocalProxy(port: number) else {
            throw QuotaError.message("В настройках ChatGPT Proxy отсутствует корректный LOCAL_PORT. Прямое подключение не используется.")
        }
        return proxy
    }
    public static func claude(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DesktopProfile] {
        let support=home.appendingPathComponent("Library/Application Support")
        var profiles: [DesktopProfile] = []
        let root=home.appendingPathComponent(".config/atlas-claude-proxy/profiles")
        for number in 1...20 {
            let file=root.appendingPathComponent("profile\(number).conf")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var directory=support.appendingPathComponent("ATLAS-Claude-Proxy/Profile\(number)")
            var title="ATLAS · Профиль \(number)", proxy: LocalProxy?, error: String?
            do {
                let values=try read(file)
                if let name=values["PROFILE_IMYA"], !name.isEmpty { title="ATLAS · \(name.prefix(80))" }
                if let path=values["PROFILE_DATA_DIR"], !path.isEmpty {
                    guard path.hasPrefix("/"), !path.contains("\0") else { throw QuotaError.message("ATLAS: путь профиля должен быть абсолютным.") }
                    directory=URL(fileURLWithPath: path, isDirectory: true)
                }
                guard let port=values["LOCAL_PORT"].flatMap(Int.init), let value=LocalProxy(port: port) else {
                    throw QuotaError.message("ATLAS: некорректный LOCAL_PORT в профиле \(number). Прямое подключение не используется.")
                }
                proxy=value
            } catch let failure { error=failure.localizedDescription }
            profiles.append(.init(id: "atlas-\(number)", title: title, directory: directory, proxy: proxy, configurationError: error))
        }
        let regular=support.appendingPathComponent("Claude")
        if FileManager.default.fileExists(atPath: regular.path) {
            profiles.append(.init(id: "desktop", title: "Claude Desktop · обычный профиль", directory: regular, proxy: nil))
        }
        return profiles
    }
    public static func selectedClaude(_ profiles: [DesktopProfile], id: String?) throws -> DesktopProfile? {
        if let id, !id.isEmpty, id != "auto" {
            guard let profile=profiles.first(where: { $0.id == id }) else {
                throw QuotaError.authentication("Выбранный профиль Claude больше не найден. Выберите профиль подключения заново.")
            }
            return profile
        }
        let atlas=profiles.filter(\.isAtlas)
        guard atlas.count <= 1 else { throw QuotaError.authentication("Найдено несколько профилей ATLAS. Выберите нужный профиль Claude в Quota.") }
        return atlas.first ?? profiles.first
    }
}
