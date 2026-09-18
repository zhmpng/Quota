import Foundation

public enum SnapshotStore {
    public static let groupID = Bundle.main.object(forInfoDictionaryKey:"QuotaAppGroup") as? String ?? "group.local.quota.widgets"
    public static var systemWidgetsEnabled: Bool { Bundle.main.object(forInfoDictionaryKey:"QuotaEnableSystemWidgets") as? Bool == true }
    public static func sharedDirectory() -> URL? {
        guard systemWidgetsEnabled else{return nil}
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:groupID)
    }
    public static func appDirectory() -> URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Quota",isDirectory:true)
    }
    public static func load(from directory: URL) -> DashboardSnapshot {
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("snapshot.json")),data.count<2_000_000,
              let value=try? JSONDecoder().decode(DashboardSnapshot.self,from:data),value.schemaVersion == 1 else{return .init()}
        return value
    }
    public static func save(_ snapshot: DashboardSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=directory.appendingPathComponent("snapshot.json")
        let data=try JSONEncoder().encode(snapshot)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public static func widgetSnapshot() -> DashboardSnapshot {
        guard let directory=sharedDirectory() else{return .init()}; return load(from:directory)
    }
    public static func persist(_ snapshot: DashboardSnapshot) throws {
        try save(snapshot,to:appDirectory())
        if let shared=sharedDirectory() {try save(.init(providers:snapshot.providers.map {$0.redactedForWidget()}),to:shared)}
    }
}
