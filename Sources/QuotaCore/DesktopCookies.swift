import Foundation
import SQLite3
import CommonCrypto
import CryptoKit

/// Reads only Claude's sessionKey from the selected Electron profile, including live WAL pages.
/// No browser profiles, other cookies, or credential copies are scanned or written.
public enum DesktopCookies {
    public struct Cookie {
        public let host: String
        public let plaintext: String
        public let encrypted: Data
        public let schema: Int
        public let updated: Int64
    }
    public static func databases(in directory: URL) -> [URL] {
        var roots=[directory, directory.appendingPathComponent("Default")]
        let partitions=directory.appendingPathComponent("Partitions")
        let children=(try? FileManager.default.contentsOfDirectory(at: partitions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        roots += children.prefix(32).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        return roots.flatMap { [$0.appendingPathComponent("Cookies"), $0.appendingPathComponent("Network/Cookies")] }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public static func read(from file: URL, now: Date = Date()) throws -> [Cookie] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw QuotaError.message("Не удалось прочитать профиль Claude Desktop. Проверьте доступ к его папке.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        var meta: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &meta, nil) == SQLITE_OK else {
            throw QuotaError.message("Неподдерживаемый формат профиля Claude Desktop.")
        }
        defer { sqlite3_finalize(meta) }
        guard sqlite3_step(meta) == SQLITE_ROW else { throw QuotaError.message("В профиле Claude нет версии хранилища сессий.") }
        let schema=Int(sqlite3_column_int(meta, 0))
        var statement: OpaquePointer?
        let sql="SELECT host_key, value, encrypted_value, last_access_utc FROM cookies WHERE name='sessionKey' AND host_key IN ('claude.ai','.claude.ai') AND path='/' AND (expires_utc=0 OR expires_utc>?) ORDER BY last_access_utc DESC LIMIT 16"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw QuotaError.message("Неподдерживаемый формат сессии Claude Desktop.") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
        var result: [Cookie] = []
        while true {
            let status=sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw QuotaError.message("Профиль Claude занят. Повторите обновление через несколько секунд.") }
            guard let host=sqlite3_column_text(statement, 0) else { continue }
            let plain=sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count=Int(sqlite3_column_bytes(statement, 2))
            guard count < 64_000 else { continue }
            let bytes=sqlite3_column_blob(statement, 2)
            let encrypted=bytes.map { Data(bytes: $0, count: count) } ?? Data()
            result.append(.init(host: String(cString: host), plaintext: plain, encrypted: encrypted, schema: schema, updated: sqlite3_column_int64(statement, 3)))
        }
        return result
    }
    public static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 16_384 && value.utf8.allSatisfy { (0x21...0x7E).contains($0) && $0 != 0x3B }
    }
    public static func decrypt(_ cookie: Cookie, password: Data?) throws -> String {
        if cookie.encrypted.isEmpty, validSession(cookie.plaintext) { return cookie.plaintext }
        guard cookie.plaintext.isEmpty, cookie.encrypted.starts(with: Data("v10".utf8)), let password, !password.isEmpty else {
            throw QuotaError.authentication("Не удалось открыть сеанс Claude Desktop. Нажмите «Сеанс Claude Desktop» для доступа к Связке ключей.")
        }
        var key=[UInt8](repeating: 0, count: 16)
        let salt=Array("saltysalt".utf8)
        let derived=password.withUnsafeBytes { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress, password.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        let input=Array(cookie.encrypted.dropFirst(3)), iv=[UInt8](repeating: 0x20, count: 16)
        var output=[UInt8](repeating: 0, count: input.count + 16), length=0
        let status=CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                           key, key.count, iv, input, input.count, &output, output.count, &length)
        guard derived == kCCSuccess, status == kCCSuccess else { throw QuotaError.authentication("Не удалось расшифровать сессию Claude Desktop. Откройте Claude и обновите подключение.") }
        var data=Data(output.prefix(length))
        if cookie.schema >= 24 {
            let hash=Data(SHA256.hash(data: Data(cookie.host.utf8)))
            guard data.count >= hash.count, data.prefix(hash.count) == hash else { throw QuotaError.authentication("Сессия Claude Desktop не прошла проверку домена.") }
            data.removeFirst(hash.count)
        }
        guard let value=String(data: data, encoding: .utf8), validSession(value) else { throw QuotaError.authentication("Некорректная сессия Claude Desktop.") }
        return value
    }
}
