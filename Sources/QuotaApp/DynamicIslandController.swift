import AppKit
import Combine
import QuartzCore
import SwiftUI
import QuotaCore
import QuotaUI

struct IslandEnvironment {
    var running: Set<Provider>
    var geometry: IslandGeometry?

    @MainActor static func current() -> Self {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap {
            IslandPolicy.provider(forBundleIdentifier: $0.bundleIdentifier, isTerminated: $0.isTerminated)
        })
        let geometry = NSScreen.screens.compactMap { screen -> IslandGeometry? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return IslandGeometry(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                                  isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0)
        }.first
        return Self(running: running, geometry: geometry)
    }
}

@MainActor private final class IslandPresentation: ObservableObject {
    @Published var snapshot = ProviderSnapshot(provider: .claude)
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 184
    @Published var notchHeight: CGFloat = 34
}

@MainActor final class DynamicIslandController: ObservableObject {
    @Published private(set) var selectedProvider: Provider?
    @Published private(set) var runningProviders: Set<Provider> = []
    @Published private(set) var hasSupportedDisplay = false
    var onOpenProvider: ((Provider) -> Void)?

    private let defaults: UserDefaults
    private let readEnvironment: @MainActor () -> IslandEnvironment
    private let presentation = IslandPresentation()
    private var dashboard = DashboardSnapshot()
    private var geometry: IslandGeometry?
    private var panel: DynamicIslandPanel?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var eventMonitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var pointerInside = false
    private var started = false
    private var suspended = false

    init(defaults: UserDefaults = .standard, environment: @escaping @MainActor () -> IslandEnvironment = { IslandEnvironment.current() }) {
        self.defaults = defaults
        self.readEnvironment = environment
        selectedProvider = defaults.string(forKey: IslandPolicy.preferenceKey).flatMap(Provider.init(rawValue:))
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(workspace, name) { $0.refreshEnvironment() }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.suspended = true; $0.reconcile() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.suspended = false; $0.refreshEnvironment() }
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshEnvironment() }
        refreshEnvironment()
    }

    func stop() {
        started = false
        hoverTask?.cancel(); hoverTask = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        removeMouseMonitors()
        panel?.orderOut(nil); panel?.close(); panel = nil
        presentation.expanded = false
        onOpenProvider = nil
    }

    func update(_ dashboard: DashboardSnapshot) {
        self.dashboard = dashboard
        if let selectedProvider { presentation.snapshot = dashboard.snapshot(selectedProvider) }
    }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        let selection = IslandPolicy.selection(current: selectedProvider, changing: provider, enabled: enabled)
        guard selection != selectedProvider else { return }
        selectedProvider = selection
        if let selection { defaults.set(selection.rawValue, forKey: IslandPolicy.preferenceKey) }
        else { defaults.removeObject(forKey: IslandPolicy.preferenceKey) }
        cancelHover()
        presentation.expanded = false
        refreshEnvironment()
    }

    func refreshEnvironment() {
        let environment = readEnvironment()
        runningProviders = environment.running
        geometry = environment.geometry
        hasSupportedDisplay = geometry != nil
        reconcile()
    }

    private func reconcile() {
        guard started, IslandPolicy.isVisible(selected: selectedProvider, running: runningProviders,
                                               hasDisplay: geometry != nil, suspended: suspended),
              let selectedProvider, let geometry else {
            cancelHover()
            presentation.expanded = false
            panel?.orderOut(nil)
            removeMouseMonitors()
            return
        }
        presentation.snapshot = dashboard.snapshot(selectedProvider)
        presentation.notchWidth = geometry.notchWidth
        presentation.notchHeight = geometry.notchHeight
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        panel.setFrame(geometry.frame(expanded: presentation.expanded), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        installMouseMonitors()
        pointerMoved(to: NSEvent.mouseLocation)
    }

    private func makePanel() -> DynamicIslandPanel {
        let panel = DynamicIslandPanel()
        let content = IslandPanelContent(presentation: presentation, onToggle: { [weak self] in
            guard let self else { return }
            self.setExpanded(!self.presentation.expanded)
            // Only an explicit click takes keyboard focus; hovering never does.
            if self.presentation.expanded { self.panel?.makeKey() }
        }, onOpen: { [weak self] in
            guard let self, let provider = self.selectedProvider else { return }
            self.setExpanded(false)
            self.onOpenProvider?(provider)
        })
        panel.contentView = NSHostingView(rootView: content)
        panel.onEscape = { [weak self] in self?.setExpanded(false) }
        return panel
    }

    func setExpanded(_ expanded: Bool) {
        hoverTask?.cancel(); hoverTask = nil
        guard let panel, panel.isVisible, let geometry, expanded != presentation.expanded else { return }
        presentation.expanded = expanded
        if !expanded, panel.isKeyWindow { panel.resignKey() }
        let frame = geometry.frame(expanded: expanded)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.38 : 0.30
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Uses the visible shape, not a permanent expanded transparent rectangle.
    func pointerMoved(to point: NSPoint) {
        guard let panel, panel.isVisible else { return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let shape = QuotaIslandShape(expanded: presentation.expanded).path(in: CGRect(origin: .zero, size: panel.frame.size))
        let inside = shape.contains(local)
        panel.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        if inside && presentation.expanded { return }
        if !inside && panel.isKeyWindow { return }
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(inside ? 140 : 220)) } catch { return }
            guard let self, self.pointerInside == inside else { return }
            self.setExpanded(inside)
        }
    }

    private func cancelHover() {
        hoverTask?.cancel(); hoverTask = nil
        pointerInside = false
    }
    private func installMouseMonitors() {
        guard eventMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerMoved(to: NSEvent.mouseLocation) }
        }) { eventMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in self?.pointerMoved(to: NSEvent.mouseLocation) }
            return event
        }) { eventMonitors.append(local) }
    }
    private func removeMouseMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor (DynamicIslandController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in if let self, self.started { action(self) } }
        }
        observers.append((center, observer))
    }
}

@MainActor private struct IslandPanelContent: View {
    @ObservedObject var presentation: IslandPresentation
    let onToggle: () -> Void
    let onOpen: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            QuotaIslandView(snapshot: presentation.snapshot, now: context.date, expanded: presentation.expanded,
                            notchWidth: presentation.notchWidth, notchHeight: presentation.notchHeight,
                            onToggle: onToggle, onOpen: onOpen)
        }
    }
}

@MainActor private final class DynamicIslandPanel: NSPanel {
    var onEscape: (() -> Void)?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("quota.dynamic-island")
        title = "Quota · Динамический остров"
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        isFloatingPanel = true; hidesOnDeactivate = false; canHide = false
        isMovable = false; isReleasedWhenClosed = false; isRestorable = false
        isExcludedFromWindowsMenu = true; tabbingMode = .disallowed
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = .statusBar
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        setAccessibilityLabel("Лимиты Quota")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
