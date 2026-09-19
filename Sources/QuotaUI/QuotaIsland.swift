import SwiftUI
import QuotaCore

/// Original Quota shape: small concave shoulders join the screen's upper edge.
public struct QuotaIslandShape: Shape {
    public var expanded: Bool
    public init(expanded: Bool) { self.expanded = expanded }
    public func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = expanded ? 10 : 6
        let bottom: CGFloat = expanded ? 24 : 14
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The shipping island content also supplies the synthetic README renders.
public struct QuotaIslandView: View {
    public let snapshot: ProviderSnapshot
    public let now: Date
    public let expanded: Bool
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    public let onToggle: () -> Void
    public let onOpen: () -> Void

    public init(snapshot: ProviderSnapshot, now: Date, expanded: Bool, notchWidth: CGFloat, notchHeight: CGFloat,
                onToggle: @escaping () -> Void = {}, onOpen: @escaping () -> Void = {}) {
        self.snapshot = snapshot; self.now = now; self.expanded = expanded
        self.notchWidth = notchWidth; self.notchHeight = notchHeight
        self.onToggle = onToggle; self.onOpen = onOpen
    }
    private var value: Double? { snapshot.visibleRemaining(at: now) }
    private var color: Color { QuotaPalette.valueColor(snapshot, at: now, scheme: .dark) }
    private var secondary: Color { Color(hex: 0xADB3A8) }
    private var name: String { snapshot.provider == .claude ? "Claude" : "Codex (ChatGPT)" }
    private var percent: String { QuotaFormatting.percent(value) + (value == nil ? "" : "%") }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Button(action: onToggle) {
                    HStack(spacing: 0) {
                        ProviderLogo(snapshot.provider).frame(width: 21, height: 21)
                            .frame(width: max(0, (proxy.size.width - notchWidth) / 2))
                        Color.clear.frame(width: notchWidth)
                        Text(percent).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(color)
                            .frame(width: max(0, (proxy.size.width - notchWidth) / 2))
                    }.frame(height: notchHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(name), \(value == nil ? "остаток неизвестен" : "осталось \(percent)")")
                    .accessibilityHint(expanded ? "Свернуть остров" : "Раскрыть лимиты")
                if expanded { details.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 16) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(.black, in: QuotaIslandShape(expanded: expanded))
            .contentShape(QuotaIslandShape(expanded: expanded))
            .clipped()
        }
        .foregroundStyle(Color(hex: 0xF2F3ED))
        .environment(\.colorScheme, .dark)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(snapshot.plan ?? "—").font(.system(size: 11)).foregroundStyle(secondary)
                    .lineLimit(1).frame(maxWidth: 120, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0x353A32), lineWidth: 1))
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(percent).font(.system(size: 37, weight: .regular)).tracking(-1).monospacedDigit().foregroundStyle(color)
                if value != nil { Text("осталось").font(.system(size: 11)).foregroundStyle(secondary) }
                Spacer(minLength: 4)
                Text(snapshot.selectedWindow?.title ?? snapshot.status(at: now))
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }.frame(height: 42)
            RemainingBar(value: value, accent: color, track: Color(hex: 0x252B23)).frame(height: 6)
                .accessibilityElement(children: .ignore).accessibilityLabel("Остаток лимита: \(percent)")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сброс лимита").font(.system(size: 11)).foregroundStyle(secondary)
                    Text(resetDate).font(.system(size: 12)).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(resetStatus).font(.system(size: 11)).foregroundStyle(secondary)
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }.frame(minHeight: 32)
            Button(action: onOpen) {
                HStack { Text("Открыть в Quota"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 11)).foregroundStyle(secondary)
                    .padding(.top, 9).contentShape(Rectangle())
            }.buttonStyle(.plain).overlay(alignment: .top) { Color(hex: 0x272D23).frame(height: 1) }
        }
    }
    private var resetDate: String {
        guard let date = snapshot.selectedWindow?.resetsAt else { return "Неизвестен" }
        if date <= now { return "Ждём подтверждения" }
        return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "ru_RU")))
    }
    private var resetStatus: String {
        if value == nil { return snapshot.status(at: now) }
        if snapshot.stale(at: now) {
            return "Данные устарели" + (snapshot.observedAt.map { "\nот " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
        }
        guard let reset = snapshot.selectedWindow?.resetsAt, reset > now else { return snapshot.status(at: now) }
        let minutes = max(1, Int(ceil(reset.timeIntervalSince(now) / 60)))
        return minutes >= 60 ? "через \(minutes / 60) ч \(minutes % 60) мин" : "через \(minutes) мин"
    }
}
