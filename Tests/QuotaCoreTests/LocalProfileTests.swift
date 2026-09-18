import XCTest
import SQLite3
@testable import QuotaCore

final class LocalProfileTests: XCTestCase {
    private func temporary() throws -> URL {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("quota-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:folder)}
        return folder
    }
    private func write(_ text:String,_ path:URL) throws {
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try text.write(to:path,atomically:true,encoding:.utf8)
    }
    func testOnlyLiteralAllowlistedSettingsAreParsed() {
        let values=LocalProfiles.parse("LOCAL_PORT='9199'\nPROXY_PASS='never import'\nPROFILE_IMYA='D'\\''Angelo'\nPROFILE_DATA_DIR='/tmp/a path'\n")
        XCTAssertEqual(values["LOCAL_PORT"],"9199")
        XCTAssertEqual(values["PROFILE_IMYA"],"D'Angelo")
        XCTAssertEqual(values["PROFILE_DATA_DIR"],"/tmp/a path")
        XCTAssertNil(values["PROXY_PASS"])
        XCTAssertTrue(LocalProfiles.parse("LOCAL_PORT=$(touch /tmp/do-not-run)\nLOCAL_PORT=9199;echo unsafe\nLOCAL_PORT=\"$PORT\"").isEmpty)
    }
    func testCodexAutoRouteAndBrokenConfigNeverBypassesProxy() throws {
        let home=try temporary(),file=home.appendingPathComponent(".config/atlas-chatgpt-proxy/proxy.conf")
        XCTAssertNil(try LocalProfiles.codexProxy(home:home))
        try write("LOCAL_PORT='9199'",file)
        XCTAssertEqual(try LocalProfiles.codexProxy(home:home)?.port,9199)
        XCTAssertNil(try LocalProfiles.codexProxy(mode:"direct",home:home))
        try write("LOCAL_PORT='0'",file)
        XCTAssertThrowsError(try LocalProfiles.codexProxy(home:home))
        try write("LOCAL_PORT='$(echo 9199)'",file)
        XCTAssertThrowsError(try LocalProfiles.codexProxy(home:home))
    }
    func testProxyEnvironmentOverridesEveryCasingButPreservesCodexHome() {
        let proxy=LocalProxy(port:9199)!
        let env=proxy.environment(inheriting:["CODEX_HOME":"/custom/codex","https_proxy":"http://old:8","NO_PROXY":"*","OTHER":"value"])
        for name in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"] {XCTAssertEqual(env[name],proxy.url)}
        XCTAssertEqual(env["CODEX_HOME"],"/custom/codex");XCTAssertEqual(env["OTHER"],"value")
        XCTAssertEqual(env["NO_PROXY"],"127.0.0.1,localhost,::1")
        XCTAssertEqual(env["NO_PROXY"],env["no_proxy"])
        XCTAssertFalse(proxy.configuration.allowFailover)
        XCTAssertNil(LocalProxy(port:65536))
    }
    func testClaudeAtlasProfilePathsAndMultipleAccounts() throws {
        let home=try temporary(),root=home.appendingPathComponent(".config/atlas-claude-proxy/profiles")
        try write("LOCAL_PORT='8899'\nPROFILE_IMYA='Личный'",root.appendingPathComponent("profile1.conf"))
        var profiles=LocalProfiles.claude(home:home)
        XCTAssertEqual(try LocalProfiles.selectedClaude(profiles,id:"auto")?.id,"atlas-1")
        XCTAssertEqual(profiles[0].directory,home.appendingPathComponent("Library/Application Support/ATLAS-Claude-Proxy/Profile1"))
        try write("LOCAL_PORT='8909'\nPROFILE_DATA_DIR='/tmp/Claude other profile'",root.appendingPathComponent("profile2.conf"))
        profiles=LocalProfiles.claude(home:home)
        XCTAssertThrowsError(try LocalProfiles.selectedClaude(profiles,id:"auto"))
        let second=try XCTUnwrap(LocalProfiles.selectedClaude(profiles,id:"atlas-2"))
        XCTAssertEqual(second.directory.path,"/tmp/Claude other profile")
        XCTAssertEqual(try second.validatedProxy()?.port,8909)
        XCTAssertThrowsError(try LocalProfiles.selectedClaude(profiles,id:"atlas-3"))
        try write("LOCAL_PORT='invalid'",root.appendingPathComponent("profile2.conf"))
        let invalid=try XCTUnwrap(LocalProfiles.selectedClaude(LocalProfiles.claude(home:home),id:"atlas-2"))
        XCTAssertThrowsError(try invalid.validatedProxy())
    }
    func testQuotedConfigCannotExecuteCommands() throws {
        let home=try temporary(),marker=home.appendingPathComponent("must-not-exist")
        let file=home.appendingPathComponent(".config/atlas-chatgpt-proxy/proxy.conf")
        try write("LOCAL_PORT=$(touch '\(marker.path)')",file)
        XCTAssertThrowsError(try LocalProfiles.codexProxy(home:home))
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    // Ciphertexts independently generated with Python PBKDF2 + openssl AES-128-CBC.
    private let legacy="763130989f25387bae0af984e07eb8bf70c0e0145820d81e4803722c409ed227203c85"
    private let modern="763130228d433546f9cb802fbecd9812370a7bcf36597179cd144d3d3b047fc18ec778b14836324376e1c19dc250f22067b758d7310d68e78e9d232a4b15541772cfb4"
    private func bytes(_ hex:String) -> Data {
        let chars=Array(hex);return Data(stride(from:0,to:chars.count,by:2).map {UInt8(String(chars[$0...$0+1]),radix:16)!})
    }
    func testChromiumLegacyAndDomainBoundCookies() throws {
        for (schema,cipher) in [(23,legacy),(24,modern)] {
            let cookie=DesktopCookies.Cookie(host:".claude.ai",plaintext:"",encrypted:bytes(cipher),schema:schema,updated:0)
            XCTAssertEqual(try DesktopCookies.decrypt(cookie,password:Data("quota-fixture-key".utf8)),"sk-ant-sid01-QUOTA-TEST-ONLY")
            XCTAssertThrowsError(try DesktopCookies.decrypt(cookie,password:Data("wrong key".utf8)))
        }
        let wrongDomain=DesktopCookies.Cookie(host:"claude.ai",plaintext:"",encrypted:bytes(modern),schema:24,updated:0)
        XCTAssertThrowsError(try DesktopCookies.decrypt(wrongDomain,password:Data("quota-fixture-key".utf8)))
        let unsupported=DesktopCookies.Cookie(host:".claude.ai",plaintext:"",encrypted:Data("v20encrypted".utf8),schema:24,updated:0)
        XCTAssertThrowsError(try DesktopCookies.decrypt(unsupported,password:Data("quota-fixture-key".utf8)))
    }
    func testCookieHeaderValidation() {
        XCTAssertTrue(DesktopCookies.validSession("test-session"))
        for value in ["", "value;Injected=1", "value\r\nHeader: x", "value\0", "with space"] {XCTAssertFalse(DesktopCookies.validSession(value))}
    }
    func testReadsLiveWALAndOnlyUnexpiredClaudeSession() throws {
        let folder=try temporary(),file=folder.appendingPathComponent("Cookies")
        var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path,&db),SQLITE_OK)
        defer {sqlite3_close(db)}
        let sql="""
        PRAGMA journal_mode=WAL;
        CREATE TABLE meta (key TEXT,value INTEGER);
        INSERT INTO meta VALUES('version',24);
        CREATE TABLE cookies(host_key TEXT,name TEXT,path TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,last_access_utc INTEGER);
        INSERT INTO cookies VALUES('.claude.ai','sessionKey','/','active-test',X'',0,2);
        INSERT INTO cookies VALUES('.claude.ai','sessionKey','/','expired-test',X'',1,3);
        INSERT INTO cookies VALUES('other.example','sessionKey','/','unrelated',X'',0,4);
        INSERT INTO cookies VALUES('.claude.ai','otherCookie','/','unrelated',X'',0,5);
        """
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path+"-wal"))
        var cookies=try DesktopCookies.read(from:file)
        XCTAssertEqual(cookies.count,1)
        XCTAssertEqual(try DesktopCookies.decrypt(cookies[0],password:nil),"active-test")
        XCTAssertEqual(sqlite3_exec(db,"UPDATE cookies SET value='rotated-test' WHERE value='active-test'",nil,nil,nil),SQLITE_OK)
        cookies=try DesktopCookies.read(from:file)
        XCTAssertEqual(try DesktopCookies.decrypt(cookies[0],password:nil),"rotated-test")
        XCTAssertEqual(sqlite3_exec(db,"DELETE FROM cookies WHERE value='rotated-test'",nil,nil,nil),SQLITE_OK)
        XCTAssertTrue(try DesktopCookies.read(from:file).isEmpty)
    }
    func testElectronPartitionDiscoveryStaysInsideSelectedProfile() throws {
        let folder=try temporary()
        try write("",folder.appendingPathComponent("Network/Cookies"))
        try write("",folder.appendingPathComponent("Partitions/claude/Cookies"))
        try write("",folder.appendingPathComponent("unrelated/Cookies"))
        XCTAssertEqual(DesktopCookies.databases(in:folder).count,2)
    }
}
