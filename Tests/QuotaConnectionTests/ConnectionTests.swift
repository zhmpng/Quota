import XCTest
import Network
import QuotaCore
@testable import QuotaApp

final class ConnectionTests:XCTestCase {
    @MainActor func testLiveCodexWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["QUOTA_RUN_LIVE_TEST"] == "1" else {throw XCTSkip("Opt-in live account check")}
        let connection=CodexConnection()
        defer {connection.stop()}
        let snapshot=try await connection.fetch()
        XCTAssertEqual(snapshot.provider,.openai)
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.observedAt)
    }
    func testClaudeHTTPSUsesConnectRelayAndDoesNotSendCredentialsInCleartext() async throws {
        let listener=try NWListener(using:.tcp,on:.any)
        let queue=DispatchQueue(label:"quota.test.proxy")
        let ready=expectation(description:"listening"),received=expectation(description:"CONNECT")
        listener.stateUpdateHandler={state in if case .ready=state {ready.fulfill()}}
        listener.newConnectionHandler={connection in
            connection.start(queue:queue)
            connection.receive(minimumIncompleteLength:1,maximumLength:8192) {data,_,_,_ in
                let text=data.flatMap {String(data:$0,encoding:.utf8)} ?? ""
                XCTAssertTrue(text.hasPrefix("CONNECT claude.ai:443"))
                XCTAssertFalse(text.contains("QUOTA-TEST-ONLY"))
                received.fulfill()
                connection.send(content:Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),completion:.contentProcessed {_ in connection.cancel()})
            }
        }
        listener.start(queue:queue)
        defer {listener.cancel()}
        await fulfillment(of:[ready],timeout:5)
        let port=try XCTUnwrap(listener.port)
        do {
            _=try await ProviderHTTP.get(URL(string:"https://claude.ai/api/organizations")!,headers:["Cookie":"sessionKey=QUOTA-TEST-ONLY"],proxy:LocalProxy(port:Int(port.rawValue)))
            XCTFail("A failed relay must not return data")
        } catch {XCTAssertTrue(error.localizedDescription.contains("ATLAS"))}
        await fulfillment(of:[received],timeout:5)
    }
    func testHTTPRejectsCredentialRedirectDestinationsBeforeNetworking() async {
        for url in ["http://claude.ai/api/organizations","https://claude.ai.attacker.invalid/api/organizations","https://unrelated.invalid/"] {
            do {_=try await ProviderHTTP.get(URL(string:url)!,headers:["Cookie":"sessionKey=QUOTA-TEST-ONLY"]);XCTFail("Disallowed host")}
            catch {XCTAssertTrue(error.localizedDescription.contains("Недопустимый адрес"))}
        }
    }
}
