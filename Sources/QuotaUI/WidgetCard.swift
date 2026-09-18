import SwiftUI
import WidgetKit
import QuotaCore

public enum QuotaPalette {
    public static func surface(_ scheme: ColorScheme) -> Color { Color(hex:scheme == .dark ? 0x252725 : 0xFAFAF7) }
    public static func text(_ scheme: ColorScheme) -> Color { Color(hex:scheme == .dark ? 0xF2F3ED : 0x242923) }
    public static func secondary(_ scheme: ColorScheme) -> Color { Color(hex:scheme == .dark ? 0xADB3A8 : 0x646A62) }
    public static func track(_ scheme: ColorScheme) -> Color { Color(hex:scheme == .dark ? 0x3D433A : 0xE5E8DF) }
    public static func separator(_ scheme: ColorScheme) -> Color { Color(hex:scheme == .dark ? 0x454A42 : 0xDDE1D7) }
    public static func accent(_ provider: Provider, scheme: ColorScheme) -> Color {
        Color(hex:provider == .claude ? (scheme == .dark ? 0xE7AB8D : 0xA4492A) : (scheme == .dark ? 0xA4C5AE : 0x37664F))
    }
    public static func valueColor(_ snapshot: ProviderSnapshot, at now: Date, scheme: ColorScheme) -> Color {
        if snapshot.stale(at:now) { return secondary(scheme) }
        if let value=snapshot.visibleRemaining(at:now) {
            if value<=10{return Color(hex:scheme == .dark ? 0xF39A90 : 0xAE3C34)}
            if value<=20{return Color(hex:scheme == .dark ? 0xE5BE73 : 0x886018)}
        }
        return accent(snapshot.provider,scheme:scheme)
    }
}

public extension Color {
    init(hex: UInt32) {self.init(.sRGB,red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,opacity:1)}
}

/// Shared content for the four gallery variants.
public struct QuotaWidgetCard: View {
    public let dashboard: DashboardSnapshot
    public let provider: Provider?
    public let compact: Bool
    public let now: Date
    public let linksEnabled: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    public init(dashboard: DashboardSnapshot, provider: Provider? = nil, compact: Bool = false, now: Date = Date(), linksEnabled: Bool = true) {
        self.dashboard=dashboard;self.provider=provider;self.compact=compact;self.now=now;self.linksEnabled=linksEnabled
    }
    private var visibleProviders:[Provider] {provider.map {[$0]} ?? [.claude,.openai]}
    private var oldest: Date? {visibleProviders.map {dashboard.snapshot($0)}.filter {!$0.windows.isEmpty}.compactMap(\.observedAt).min()}
    private var monochrome:Bool {mode != .fullColor}
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(provider == nil ? "Лимиты подписки" : "Остаток лимита").font(.system(size:11,weight:.semibold))
                Spacer(minLength:3)
                Text(oldest.map {$0.formatted(date:.omitted,time:.shortened)} ?? "—")
                    .font(.system(size:10)).monospacedDigit()
                    .foregroundStyle(monochrome ? Color.primary : QuotaPalette.secondary(scheme)).opacity(monochrome ? 0.7 : 1)
            }.frame(height:14)
            if let provider {service(provider)}
            else if compact {
                VStack(spacing:12) {compactService(.claude);compactService(.openai)}
            }
            else {
                HStack(alignment:.top,spacing:24) {service(.claude);service(.openai)}
                    .overlay {
                        Rectangle().fill(monochrome ? Color.primary : QuotaPalette.separator(scheme))
                            .opacity(monochrome ? 0.22 : 1).frame(width:1).allowsHitTesting(false)
                    }
            }
            Spacer(minLength:0)
        }.padding(16).foregroundStyle(monochrome ? Color.primary : QuotaPalette.text(scheme))
    }
    @ViewBuilder private func service(_ provider: Provider) -> some View {
        let snapshot=dashboard.snapshot(provider)
        if linksEnabled {
            Link(destination:URL(string:"quota://provider/\(provider.rawValue)")!) {
                ProviderQuotaView(snapshot:snapshot,now:now)
            }.buttonStyle(.plain)
        } else {ProviderQuotaView(snapshot:snapshot,now:now)}
    }
    @ViewBuilder private func compactService(_ provider: Provider) -> some View {
        let snapshot=dashboard.snapshot(provider)
        if linksEnabled {
            Link(destination:URL(string:"quota://provider/\(provider.rawValue)")!) {
                CompactProviderQuotaView(snapshot:snapshot,now:now)
            }.buttonStyle(.plain)
        } else {CompactProviderQuotaView(snapshot:snapshot,now:now)}
    }
}

private struct CompactProviderQuotaView: View {
    let snapshot: ProviderSnapshot
    let now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    private var value:Double? {snapshot.visibleRemaining(at:now)}
    private var monochrome:Bool {mode != .fullColor}
    private var accent:Color {monochrome ? .primary : QuotaPalette.valueColor(snapshot,at:now,scheme:scheme)}
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:5) {
                ProviderLogo(snapshot.provider).frame(width:15,height:15)
                Text(snapshot.widgetName).font(.system(size:11,weight:.semibold)).lineLimit(1)
                Spacer(minLength:1)
                Text(QuotaFormatting.percent(value)+(value == nil ? "" : "%"))
                    .font(.system(size:19,weight:.medium)).tracking(-0.6).monospacedDigit().foregroundStyle(accent)
            }.frame(height:22)
            RemainingBar(value:value,accent:accent,track:QuotaPalette.track(scheme)).frame(height:4)
            Text(value == nil ? snapshot.status(at:now) : QuotaFormatting.reset(snapshot.selectedWindow?.resetsAt,now:now,compact:false))
                .font(.system(size:9)).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(monochrome ? Color.primary : QuotaPalette.secondary(scheme)).opacity(monochrome ? 0.7 : 1)
                .frame(height:12,alignment:.leading)
        }.frame(maxWidth:.infinity,alignment:.leading)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("\(snapshot.widgetName), \(value.map {"осталось \(QuotaFormatting.percent($0)) процентов"} ?? "остаток неизвестен"), \(snapshot.status(at:now)), \(QuotaFormatting.reset(snapshot.selectedWindow?.resetsAt,now:now,compact:false))")
    }
}

public struct ProviderQuotaView: View {
    public let snapshot: ProviderSnapshot
    public let now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    public init(snapshot: ProviderSnapshot, now: Date = Date()) {self.snapshot=snapshot;self.now=now}
    private var value: Double? {snapshot.visibleRemaining(at:now)}
    private var monochrome:Bool {mode != .fullColor}
    private var accent: Color {monochrome ? .primary : QuotaPalette.valueColor(snapshot,at:now,scheme:scheme)}
    private var secondary:Color {monochrome ? .primary : QuotaPalette.secondary(scheme)}
    public var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:6) {
                ProviderLogo(snapshot.provider).frame(width:18,height:18)
                Text(snapshot.widgetName).font(.system(size:12,weight:.semibold)).lineLimit(1)
                Spacer(minLength:1)
                if let plan=snapshot.plan {Text(plan).font(.system(size:10)).foregroundStyle(secondary).opacity(monochrome ? 0.7 : 1).lineLimit(1).minimumScaleFactor(0.8)}
            }.frame(height:18)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                number
                if value != nil {Text("осталось").font(.system(size:10)).foregroundStyle(secondary).opacity(monochrome ? 0.7 : 1)}
            }.frame(height:39,alignment:.leading).padding(.top,3)
            Text(snapshot.status(at:now)).lineLimit(1).minimumScaleFactor(0.85)
                .font(.system(size:11)).foregroundStyle(secondary).opacity(monochrome ? 0.7 : 1)
                .frame(height:14,alignment:.leading)
            RemainingBar(value:value,accent:accent,track:QuotaPalette.track(scheme))
                .frame(height:6).padding(.top,8)
            Text(value != nil ? QuotaFormatting.reset(snapshot.selectedWindow?.resetsAt,now:now,compact:false) : missingCaption)
                .font(.system(size:11)).foregroundStyle(secondary).opacity(monochrome ? 0.7 : 1).lineLimit(1)
                .frame(height:14,alignment:.leading).padding(.top,7)
        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            .accessibilityElement(children:.ignore).accessibilityLabel(accessibilityText)
    }
    private var number: some View {
        HStack(alignment:.firstTextBaseline,spacing:1) {
            Text(QuotaFormatting.percent(value)).font(.system(size:34,weight:.regular)).tracking(-1.4)
            if value != nil {Text("%").font(.system(size:20,weight:.regular))}
        }.monospacedDigit().foregroundStyle(accent).fixedSize(horizontal:true,vertical:false)
    }
    private var missingCaption: String {snapshot.state == .disconnected ? "Настроить в Quota" : snapshot.state == .reauth ? "Открыть подключение" : "Открыть подробности"}
    private var accessibilityText: String {
        let remaining=value.map {"осталось \(QuotaFormatting.percent($0)) процентов"} ?? "остаток неизвестен"
        return "\(snapshot.widgetName), \(remaining), \(snapshot.status(at:now)), \(QuotaFormatting.reset(snapshot.selectedWindow?.resetsAt,now:now,compact:false)). Открыть Quota."
    }
}

public struct RemainingBar: View {
    public let value: Double?
    public let accent: Color
    public let track: Color
    @Environment(\.widgetRenderingMode) private var mode
    public init(value: Double?, accent: Color, track: Color) {self.value=value;self.accent=accent;self.track=track}
    private var validValue:Double? {guard let value,value.isFinite,value>=0,value<=100 else{return nil};return value}
    public var body: some View {
        GeometryReader { proxy in
            let monochrome=mode != .fullColor
            ZStack(alignment:.leading) {
                if let value=validValue {
                    // WidgetKit replaces RGB colors in accented/vibrant mode. View opacity survives.
                    Capsule().fill(monochrome ? Color.primary : track).opacity(monochrome ? 0.20 : 1)
                    if value>0 {
                        Capsule().fill(monochrome ? Color.primary : accent)
                            .frame(width:proxy.size.width*value/100)
                    }
                } else {
                    // Unknown is an unfilled dashed rail, never a bar that looks like 100%.
                    Capsule().strokeBorder(style:StrokeStyle(lineWidth:1,dash:[2,3]))
                        .foregroundStyle(monochrome ? Color.primary : accent).opacity(monochrome ? 0.38 : 0.45)
                }
            }
        }.accessibilityHidden(true)
    }
}

public enum DemoData {
    public static func make(now: Date = Date()) -> DashboardSnapshot {
        .init(providers:[
            .init(provider:.claude,state:.ready,plan:"Pro",source:"Демонстрация",observedAt:now,
                windows:[.init(id:"five_hour",title:"Сессия · 5 ч",compactTitle:"Сессия",bucket:"claude",usedPercent:36,resetsAt:now.addingTimeInterval(7680),isShared:true)],isDemo:true),
            .init(provider:.openai,state:.ready,plan:"Plus",source:"Демонстрация",observedAt:now,
                windows:[.init(id:"codex-primary",title:"Сессия · 5 ч",compactTitle:"Сессия",bucket:"codex",usedPercent:62,resetsAt:now.addingTimeInterval(2580),isShared:true)],isDemo:true)
        ])
    }
}
