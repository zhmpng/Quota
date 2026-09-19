import SwiftUI
import QuotaCore
import QuotaUI

struct DynamicIslandSettings: View {
    let provider: Provider
    @ObservedObject var island: DynamicIslandController
    @Environment(\.colorScheme) private var scheme
    @State private var replacement: String?
    private var enabled: Bool { island.selectedProvider == provider }
    private var appName: String { provider == .claude ? "Claude Desktop" : "Codex / ChatGPT" }
    private var providerName: String { provider == .claude ? "Claude" : "Codex (ChatGPT)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { enabled }, set: { newValue in
                let previous = island.selectedProvider
                island.setEnabled(newValue, for: provider)
                if newValue, let previous, previous != provider {
                    replacement = "Остров \(previous == .claude ? "Claude" : "Codex (ChatGPT)") выключен. Выбран \(providerName)."
                } else { replacement = nil }
            })) {
                HStack(spacing: 10) {
                    Image(systemName: "macbook").font(.system(size: 21)).frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Динамический остров").font(.system(size: 13, weight: .medium))
                        Text("Лимиты рядом с вырезом экрана").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.toggleStyle(.switch).accessibilityLabel("Динамический остров для \(providerName)")
            Divider()
            HStack {
                Text("Показывать, пока запущено").foregroundStyle(.secondary)
                Spacer()
                Text(appName)
            }.font(.system(size: 11))
            Text(provider == .openai ? "Показывает те же лимиты Codex в подписке ChatGPT, что и виджет." : "Использует тот же период и остаток, что и виджет Claude.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Одновременно активен один провайдер. После завершения приложения остров скрывается; выбор сохраняется.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(enabled && island.runningProviders.contains(provider) && island.hasSupportedDisplay ? QuotaPalette.accent(provider, scheme: scheme) : .secondary)
                    .frame(width: 5, height: 5)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            if let replacement { Text(replacement).font(.system(size: 11)).foregroundStyle(QuotaPalette.accent(provider, scheme: scheme)) }
        }.padding(16)
            .background(QuotaPalette.track(scheme).opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: provider) { _, _ in replacement = nil }
    }
    private var status: String {
        guard enabled else {
            if let selected = island.selectedProvider { return "Выключен · остров выбран для \(selected == .claude ? "Claude" : "Codex (ChatGPT)")" }
            return "Выключен"
        }
        guard island.hasSupportedDisplay else { return "Ожидает встроенного экрана MacBook с вырезом" }
        return island.runningProviders.contains(provider) ? "Включён · \(appName) запущен" : "Ожидает запуска \(appName)"
    }
}
