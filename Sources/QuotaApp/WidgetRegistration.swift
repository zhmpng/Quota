import AppKit
import CoreServices
import OSLog
import WidgetKit

/// Refresh the registration after a Finder replacement or a new signed build.
/// Never delete WidgetKit's databases: they contain the user's widget positions.
enum WidgetRegistration {
    private static let log = Logger(subsystem: "local.quota.app", category: "installation")
    private static let markerKey = "widgetRegistrationFingerprint.v1"

    static func updateIfNeeded() async {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard appURL.pathExtension == "app",
              let appID = Bundle.main.bundleIdentifier,
              let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("QuotaWidgets.appex"),
              let extensionBundle = Bundle(url: extensionURL),
              let extensionID = extensionBundle.bundleIdentifier else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let executableDate = (try? extensionBundle.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fingerprint = "\(appURL.path)|\(version)|\(build)|\(executableDate)"
        guard UserDefaults.standard.string(forKey: markerKey) != fingerprint else {
            log.info("Widget registration unchanged; skipping")
            return
        }
        let succeeded = await Task.detached(priority: .utility) {
            // Force Launch Services to reread the app icon and embedded extension metadata.
            let status = LSRegisterURL(appURL as CFURL, true)
            guard status == noErr else {
                log.error("Launch Services registration failed: \(status)")
                return false
            }
            guard run("/usr/bin/pluginkit", ["-a", extensionURL.path]).status == 0 else { return false }

            // Copies left in Downloads or a build folder must not take precedence over
            // the app the user installed. Keep all files; remove only duplicate records.
            let installed = appURL.deletingLastPathComponent().path == "/Applications" ||
                appURL.deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            if installed {
                let listing = run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-vv", "-i", extensionID])
                if listing.status == 0 {
                    for line in listing.output.components(separatedBy: .newlines) {
                        let field = line.trimmingCharacters(in: .whitespaces)
                        guard field.hasPrefix("Path = ") else { continue }
                        let other = URL(fileURLWithPath: String(field.dropFirst(7))).resolvingSymlinksInPath()
                        guard other != extensionURL.resolvingSymlinksInPath(),
                              Bundle(url: other)?.bundleIdentifier == extensionID else { continue }
                        let parent = other.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        guard Bundle(url: parent)?.bundleIdentifier == appID else { continue }
                        _ = run("/usr/bin/pluginkit", ["-r", other.path])
                    }
                }
            }
            return true
        }.value
        guard succeeded else { return } // Retry at the next launch if registration failed.
        WidgetCenter.shared.invalidateConfigurationRecommendations()
        WidgetCenter.shared.reloadAllTimelines()
        UserDefaults.standard.set(fingerprint, forKey: markerKey)
        log.info("Updated widget registration for version \(version, privacy: .public) build \(build, privacy: .public)")
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: deadline)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            deadline.cancel()
            log.error("Registration tool failed to launch")
            return (-1, "")
        }
    }
}
