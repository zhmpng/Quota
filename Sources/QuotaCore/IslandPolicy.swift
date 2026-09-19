import Foundation
import CoreGraphics

/// A single persisted choice makes provider activation mutually exclusive.
public enum IslandPolicy {
    public static let preferenceKey = "dynamicIslandProvider"

    public static func provider(forBundleIdentifier identifier: String?, isTerminated: Bool = false) -> Provider? {
        guard !isTerminated, let identifier else { return nil }
        switch identifier.lowercased() {
        case "com.anthropic.claudefordesktop": return .claude
        case "com.openai.codex", "com.openai.chat": return .openai
        default: return nil // In particular, Electron helpers and proxy launchers aren't the app.
        }
    }

    public static func selection(current: Provider?, changing provider: Provider, enabled: Bool) -> Provider? {
        enabled ? provider : (current == provider ? nil : current)
    }

    public static func isVisible(selected: Provider?, running: Set<Provider>, hasDisplay: Bool, suspended: Bool = false) -> Bool {
        guard let selected else { return false }
        return running.contains(selected) && hasDisplay && !suspended
    }
}

/// Coordinates are global screen points, including screens with negative origins.
public struct IslandGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let notchRect: CGRect
    public var notchWidth: CGFloat { notchRect.width }
    public var notchHeight: CGFloat { notchRect.height }
    public var collapsedSize: CGSize { CGSize(width: notchWidth + 112, height: notchHeight) }
    public var expandedSize: CGSize { CGSize(width: max(420, collapsedSize.width), height: notchHeight + 212) }

    public init?(screenFrame: CGRect, safeAreaTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?, isBuiltIn: Bool) {
        guard isBuiltIn, safeAreaTop.isFinite, safeAreaTop > 0,
              let leftArea, let rightArea else { return nil }
        let width = rightArea.minX - leftArea.maxX
        guard width.isFinite, width > 0, width + 112 <= screenFrame.width,
              leftArea.maxX >= screenFrame.minX, rightArea.minX <= screenFrame.maxX,
              screenFrame.width >= 420, safeAreaTop + 212 < screenFrame.height else { return nil }
        self.screenFrame = screenFrame
        self.notchRect = CGRect(x: leftArea.maxX, y: screenFrame.maxY - safeAreaTop, width: width, height: safeAreaTop)
    }

    public func frame(expanded: Bool) -> CGRect {
        let size = expanded ? expandedSize : collapsedSize
        return CGRect(x: notchRect.midX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}
