import SwiftUI
import WidgetKit
import QuotaCore
import QuotaUI

struct QuotaEntry: TimelineEntry {let date: Date;let dashboard: DashboardSnapshot}
struct QuotaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {.init(date:Date(),dashboard:DemoData.make())}
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry)->Void) {
        completion(.init(date:Date(),dashboard:context.isPreview ? DemoData.make() : SnapshotStore.widgetSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>)->Void) {
        let now=Date(),snapshot=SnapshotStore.widgetSnapshot()
        var dates=[now]
        for provider in snapshot.providers {
            if let reset=provider.selectedWindow?.resetsAt,reset>now,reset<now.addingTimeInterval(3600) {dates.append(reset)}
            if let observed=provider.observedAt,observed.addingTimeInterval(3601)>now {dates.append(observed.addingTimeInterval(3601))}
        }
        let entries=Set(dates).sorted().map {QuotaEntry(date:$0,dashboard:snapshot)}
        completion(Timeline(entries:entries,policy:.after(now.addingTimeInterval(900))))
    }
}
struct QuotaWidgetView: View {
    let entry: QuotaEntry
    var provider: Provider? = nil
    var compact: Bool = false
    @Environment(\.colorScheme) var scheme
    var body: some View {
        QuotaWidgetCard(dashboard:entry.dashboard,provider:provider,compact:compact,now:entry.date)
            .containerBackground(QuotaPalette.surface(scheme),for:.widget)
            .widgetURL(URL(string:provider.map {"quota://provider/\($0.rawValue)"} ?? "quota://overview"))
    }
}
struct ExistingQuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        // Preserve both existing widget families and their identifiers across updates.
        QuotaWidgetView(entry: entry, compact: family == .systemSmall)
    }
}
struct QuotaDesktopWidget: Widget {
    let kind="QuotaDesktopWidget" // Keep the existing medium widget identity across updates.
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:QuotaTimeline()) {ExistingQuotaWidgetView(entry:$0)}
            .configurationDisplayName("Claude и ChatGPT / Codex")
            .description("Два подключения рядом: остаток подписки и время сброса.")
            .supportedFamilies([.systemSmall,.systemMedium]).contentMarginsDisabled()
    }
}
struct ClaudeQuotaWidget: Widget {
    let kind="QuotaClaudeWidget"
    var body:some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:QuotaTimeline()) {QuotaWidgetView(entry:$0,provider:.claude)}
            .configurationDisplayName("Claude")
            .description("Лимит подписки Claude и время сброса.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct OpenAIQuotaWidget: Widget {
    let kind="QuotaOpenAIWidget"
    var body:some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:QuotaTimeline()) {QuotaWidgetView(entry:$0,provider:.openai)}
            .configurationDisplayName("ChatGPT / Codex")
            .description("Лимит Codex в подписке ChatGPT и время сброса.")
            .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
@main struct QuotaWidgetBundle: WidgetBundle {
    var body: some Widget {QuotaDesktopWidget();ClaudeQuotaWidget();OpenAIQuotaWidget()}
}
