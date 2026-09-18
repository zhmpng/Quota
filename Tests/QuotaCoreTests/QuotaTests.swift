import XCTest
@testable import QuotaCore

final class QuotaTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1_800_000_000)
    func testCodexBucketsAreNotMergedAndUsedIsInverted() {
        let payload:[String:Any] = ["rateLimitsByLimitId":[
            "codex":["primary":["usedPercent":36,"windowDurationMins":300,"resetsAt":1_800_001_000],"credits":["balance":"42","unlimited":false]],
            "other":["primary":["usedPercent":80,"windowDurationMins":60]]]]
        let s=CodexParser.parse(account:["account":["type":"chatgpt","planType":"pro"]],limits:payload,usage:nil,now:now)
        XCTAssertEqual(s.windows.count,2);XCTAssertEqual(s.windows[0].remaining,64);XCTAssertEqual(s.widgetName,"Codex")
        XCTAssertTrue(s.money.isEmpty);XCTAssertEqual(s.metrics.first?.value,"42")
    }
    func testMalformedMetricDoesNotInvalidateOtherBucket() {
        let s=CodexParser.parse(account:[:],limits:["rateLimitsByLimitId":["codex":["primary":["usedPercent":true],"secondary":["usedPercent":40]]]],usage:nil,now:now)
        XCTAssertEqual(s.windows.count,1);XCTAssertEqual(s.windows[0].remaining,60)
    }
    func testNoQuotaIsNotZero() {
        let s=CodexParser.parse(account:[:],limits:[:],usage:nil,now:now)
        XCTAssertEqual(s.state,.unavailable);XCTAssertNil(s.visibleRemaining(at:now));XCTAssertEqual(QuotaFormatting.percent(nil),"—")
    }
    func testClaudeCentsRequireCurrency() {
        let usage:[String:Any] = ["five_hour":["utilization":36.0,"resets_at":"2027-01-15T12:00:00Z"]]
        let s=ClaudeParser.parse(usage:usage,extra:["is_enabled":true,"used_credits":1234,"monthly_credit_limit":5000,"currency":"eur"],source:"test",now:now)
        XCTAssertEqual(s.windows.first?.remaining,64);XCTAssertEqual(s.money.first?.amount,12.34);XCTAssertEqual(s.money.first?.currency,"EUR")
        let unknown=ClaudeParser.parse(usage:usage,extra:["used_credits":1234],source:"test",now:now)
        XCTAssertTrue(unknown.money.isEmpty);XCTAssertNotNil(unknown.metrics.first?.explanation)
    }
    func testClaudeNullWindowsAndInactiveScopedLimits() {
        let s=ClaudeParser.parse(usage:["five_hour":NSNull(),"seven_day":["utilization":45],"limits":[["percent":20,"is_active":false],["percent":30,"is_active":true,"scope":["model":["id":"model-x","display_name":"Model X"]]]]],source:"test",now:now)
        XCTAssertEqual(s.windows.count,2);XCTAssertEqual(s.windows[0].id,"seven_day")
    }
    func testResetDoesNotInventFullBalance() {
        let window=QuotaWindow(id:"session",title:"Сессия",compactTitle:"Сессия",bucket:"codex",usedPercent:100,resetsAt:now.addingTimeInterval(-1))
        let s=ProviderSnapshot(provider:.openai,state:.ready,observedAt:now,windows:[window])
        XCTAssertNil(s.visibleRemaining(at:now));XCTAssertEqual(s.status(at:now),"Проверяем сброс")
    }
    func testFractionAndInvalidValues() {
        XCTAssertEqual(QuotaFormatting.percent(0.4),"<1");XCTAssertEqual(QuotaFormatting.percent(0),"0")
        XCTAssertEqual(QuotaFormatting.percent(100),"100");XCTAssertEqual(QuotaFormatting.percent(100.1),"—")
        XCTAssertEqual(QuotaFormatting.percent(.nan),"—");XCTAssertEqual(QuotaFormatting.percent(34.9),"34")
    }
    func testUnrelatedExhaustedBucketDoesNotOverride() {
        var s=ProviderSnapshot(provider:.openai,state:.ready,windows:[
            .init(id:"a",title:"A",compactTitle:"A",bucket:"codex",usedPercent:30,isShared:true),
            .init(id:"b",title:"B",compactTitle:"B",bucket:"other",usedPercent:100,isShared:true)])
        s.selectedWindowID="a";XCTAssertEqual(s.selectedWindow?.id,"a")
        s.windows.append(.init(id:"c",title:"Week",compactTitle:"Week",bucket:"codex",usedPercent:100,isShared:true))
        XCTAssertEqual(s.selectedWindow?.id,"c")
    }
    func testWidgetSnapshotStripsPrivateDetail() {
        let s=ProviderSnapshot(provider:.claude,state:.ready,accountLabel:"private@example.invalid",source:"ATLAS · private profile",metrics:[.init("private","Detail","Secret")],money:[.init(id:"cost",title:"Cost",amount:5,currency:"USD",period:"month")])
        let safe=s.redactedForWidget();XCTAssertNil(safe.accountLabel);XCTAssertTrue(safe.money.isEmpty);XCTAssertTrue(safe.metrics.isEmpty)
        XCTAssertTrue(safe.source.isEmpty)
    }
    func testSnapshotRoundtripAndCorruptFileFallback() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:dir)}
        let s=DashboardSnapshot(providers:[.init(provider:.openai,state:.ready,plan:"test")])
        try SnapshotStore.save(s,to:dir);XCTAssertEqual(SnapshotStore.load(from:dir).snapshot(.openai).plan,"test")
        try Data("invalid".utf8).write(to:dir.appendingPathComponent("snapshot.json"));XCTAssertEqual(SnapshotStore.load(from:dir).snapshot(.openai).state,.disconnected)
    }
    func testStaleCacheHasOriginalTimestamp() {
        let s=ProviderSnapshot(provider:.claude,state:.offline,observedAt:now.addingTimeInterval(-7200),windows:[.init(id:"x",title:"Session",compactTitle:"S",bucket:"claude",usedPercent:30)])
        XCTAssertTrue(s.stale(at:now));XCTAssertEqual(s.visibleRemaining(at:now),70);XCTAssertEqual(s.status(at:now),"Нет связи")
    }
    func testUnconfiguredBuildNeverRequestsAppGroupContainer() {
        XCTAssertTrue(!SnapshotStore.systemWidgetsEnabled)
        XCTAssertNil(SnapshotStore.sharedDirectory())
    }
}
