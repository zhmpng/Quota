import AppKit
import SwiftUI
import Charts
import ServiceManagement
import WidgetKit
import QuotaCore
import QuotaUI

@main struct QuotaApplication:App {
    @StateObject private var model=AppModel()
    @NSApplicationDelegateAdaptor(QuotaDelegate.self) private var delegate
    var body:some Scene {
        WindowGroup("Quota",id:"main") {
            DashboardView().environmentObject(model).frame(minWidth:880,minHeight:680)
                .task {delegate.model=model;model.start()}
                .onOpenURL {url in
                    guard url.scheme == "quota" else{return}
                    if let provider=Provider(rawValue:url.lastPathComponent) {model.selectedProvider=provider}
                    NSApp.activate(ignoringOtherApps:true)
                }
        }.defaultSize(width:1040,height:800)
        MenuBarExtra("Quota",systemImage:"gauge.with.dots.needle.50percent") {
            MenuContent().environmentObject(model)
        }.menuBarExtraStyle(.menu)
        Settings {SettingsView().environmentObject(model)}
    }
}

@MainActor final class QuotaDelegate:NSObject,NSApplicationDelegate {
    weak var model:AppModel?
    func applicationDidFinishLaunching(_ notification:Notification) {
        // Explicit local QA option: render only this application's own window, never the screen.
        let arguments=CommandLine.arguments
        if let index=arguments.firstIndex(of:"--capture-window-to"),arguments.indices.contains(index+1) {
            let path=arguments[index+1]
            Task {@MainActor in
                try? await Task.sleep(nanoseconds:12_000_000_000)
                guard let window=NSApp.windows.first(where:{$0.title == "Quota"}),let view=window.contentView,
                      let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
                view.cacheDisplay(in:view.bounds,to:rep)
                if let data=rep.representation(using:.png,properties:[:]) {try? data.write(to:URL(fileURLWithPath:path))}
                let windows=NSApp.windows.filter {$0.isVisible}.map { ["title":$0.title,"borderless":$0.styleMask.isEmpty] as [String:Any] }
                if let data=try? JSONSerialization.data(withJSONObject:windows,options:[.prettyPrinted,.sortedKeys]) {
                    try? data.write(to:URL(fileURLWithPath:URL(fileURLWithPath:path).deletingPathExtension().path+"-windows.json"))
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification) {model?.shutdown()}
}

private struct MenuContent:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        Button("Открыть Quota"){openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}
        Button("Обновить лимиты"){Task {await model.refreshAll()}}.disabled(!model.refreshing.isEmpty)
        SettingsLink {Text("Настройки…")}
        Divider()
        Button("Завершить Quota"){NSApp.terminate(nil)}
    }
}

private struct DashboardView:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showingDemo=false
    @State private var monochromePreview=false
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:24) {
                HStack(spacing:10) {QuotaAppIcon().frame(width:38,height:38);Text("Quota").font(.system(size:23,weight:.semibold))}.padding(.bottom,16)
                Text("ПОДПИСКИ").font(.system(size:10,weight:.semibold)).tracking(1.5).foregroundStyle(.secondary)
                ForEach(Provider.allCases) {provider in
                    Button {model.selectedProvider=provider} label:{
                        HStack {ProviderLogo(provider).frame(width:21,height:21);Text(provider.title).font(.system(size:12,weight:.medium));Spacer()}.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(model.selectedProvider == provider ? QuotaPalette.track(scheme) : .clear,in:RoundedRectangle(cornerRadius:9))
                }
                Spacer()
                Text("Данные подписки остаются на этом Mac.").font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(3)
                SettingsLink {Label("Настройки",systemImage:"gearshape")}.buttonStyle(.plain).font(.system(size:12))
            }.padding(24).frame(width:220).background(QuotaPalette.surface(scheme))
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:5) {Text("ЛИМИТЫ ПОДПИСКИ").font(.system(size:10,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary);Text("Остаток. Сброс. Расходы.").font(.system(size:27,weight:.medium)).tracking(-0.8)}
                        Spacer()
                        Button {Task {await model.refreshAll()}} label:{Label(model.refreshing.isEmpty ? "Обновить" : "Обновление…",systemImage:"arrow.clockwise")}.disabled(!model.refreshing.isEmpty)
                    }
                    if let notice=model.notice {noticeView(notice)}
                    preview
                    providerDetails(model.dashboard.snapshot(model.selectedProvider))
                }.padding(28)
            }
        }.background(QuotaPalette.surface(scheme).opacity(0.6))
    }
    private var preview:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("СИСТЕМНЫЕ ВИДЖЕТЫ").font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Toggle("Монохром",isOn:$monochromePreview).toggleStyle(.switch).controlSize(.mini).font(.caption)
                Toggle("Демо",isOn:$showingDemo).toggleStyle(.switch).controlSize(.mini).font(.caption)
            }
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.top,spacing:20) {widgetPreview(.openai);widgetPreview(.claude);widgetPreview(nil,compact:true);widgetPreview(nil)}
                VStack(spacing:20) {
                    HStack(alignment:.top,spacing:20) {widgetPreview(.openai);widgetPreview(.claude);widgetPreview(nil,compact:true)}
                    widgetPreview(nil)
                }
                VStack(spacing:20) {
                    HStack(alignment:.top,spacing:20) {widgetPreview(.openai);widgetPreview(.claude)}
                    widgetPreview(nil,compact:true)
                    widgetPreview(nil)
                }
            }.padding(24).frame(maxWidth:.infinity).background(LinearGradient(colors:[Color(hex:0x61715C),Color(hex:0x92947A)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:16))
            Text(showingDemo ? "Демонстрационные данные. Системные виджеты продолжают показывать ваш аккаунт." : "Правый клик на рабочем столе → «Изменить виджеты» → Quota. Для обновления лимитов оставьте приложение запущенным в строке меню.")
                .font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    private func widgetPreview(_ provider:Provider?,compact:Bool=false)->some View {
        VStack(spacing:10) {
            QuotaWidgetCard(dashboard:showingDemo ? DemoData.make() : model.dashboard,provider:provider,compact:compact,linksEnabled:false)
                .environment(\.widgetRenderingMode,monochromePreview ? .accented : .fullColor)
                .frame(width:provider == nil && !compact ? 360 : 170,height:170).background(QuotaPalette.surface(scheme),in:RoundedRectangle(cornerRadius:22))
                .shadow(color:.black.opacity(0.14),radius:14,x:0,y:6)
            Text(provider.map {($0 == .claude ? "Claude" : "ChatGPT / Codex")+" · 1 × 1"} ?? (compact ? "Вместе · 1 × 1" : "Вместе · 1 × 2")).font(.system(size:10)).foregroundStyle(.white.opacity(0.8))
        }
    }
    private func noticeView(_ text:String)->some View {
        HStack(alignment:.top) {Image(systemName:"info.circle");Text(text).textSelection(.enabled);Spacer();Button {model.notice=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel("Скрыть сообщение")}.font(.system(size:12)).padding(12).background(QuotaPalette.track(scheme).opacity(0.65),in:RoundedRectangle(cornerRadius:8))
    }
    @ViewBuilder private func providerDetails(_ snapshot:ProviderSnapshot)->some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(snapshot.provider.title).font(.system(size:22,weight:.semibold))
                    Text([snapshot.plan,snapshot.accountLabel].compactMap {$0}.joined(separator:" · ")).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if model.refreshing.contains(snapshot.provider) {ProgressView().controlSize(.small)}
                else {Text(snapshot.status(at:Date())).font(.system(size:11)).foregroundStyle(.secondary)}
            }
            if let message=snapshot.message {Text(message).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)}
            connectionButtons(snapshot.provider)
            if snapshot.provider == .claude,!model.claudeProfiles.isEmpty {
                Picker("Профиль Claude Desktop",selection:Binding(get:{model.claudeProfileID},set:{model.selectClaudeProfile($0)})) {
                    Text("Автоматически").tag("auto")
                    ForEach(model.claudeProfiles) {Text($0.title).tag($0.id)}
                }
                Text("Для профиля ATLAS оставьте запущенным его ярлык Claude Proxy. При первом подключении macOS может запросить доступ к «Claude Safe Storage».").font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.provider == .claude,!model.organizations.isEmpty {
                Picker("Организация",selection:$model.organizationID) {Text("Выберите организацию").tag("");ForEach(model.organizations) {Text($0.name).tag($0.id)}}
                    .onChange(of:model.organizationID) { _,value in model.selectOrganization(value)}
            }
            if !snapshot.windows.isEmpty {
                Picker("В виджете",selection:Binding(get:{snapshot.selectedWindow?.id ?? ""},set:{model.selectWindow($0,for:snapshot.provider)})) {
                    ForEach(snapshot.windows) {Text($0.title).tag($0.id)}
                }.font(.system(size:12))
                VStack(spacing:14) {ForEach(snapshot.windows) {window in
                    VStack(spacing:6) {
                        HStack {Text(window.title).font(.system(size:12));Spacer();Text(window.isPendingReset(at:Date()) ? "Проверяем сброс" : "\(QuotaFormatting.percent(window.remaining))% осталось").font(.system(size:12,weight:.medium)).monospacedDigit()}
                        RemainingBar(value:window.isPendingReset(at:Date()) ? nil : window.remaining,accent:QuotaPalette.accent(snapshot.provider,scheme:scheme),track:QuotaPalette.track(scheme)).frame(height:5)
                        HStack {Text(QuotaFormatting.reset(window.resetsAt,now:Date(),compact:false));Spacer();Text(window.bucket)}.font(.system(size:10)).foregroundStyle(.secondary)
                    }
                }}
            }
            Divider()
            Text("Расходы и кредиты").font(.system(size:14,weight:.semibold))
            if snapshot.money.isEmpty {Text("Сервис не передал денежную детализацию подписки. Историю платежей можно посмотреть в личном кабинете.").font(.system(size:12)).foregroundStyle(.secondary)}
            ForEach(snapshot.money) {item in HStack {VStack(alignment:.leading,spacing:3) {Text(item.title);Text(item.period).font(.caption).foregroundStyle(.secondary)};Spacer();Text(item.formatted).monospacedDigit()}.font(.system(size:12))}
            ForEach(snapshot.metrics) {item in VStack(alignment:.leading,spacing:3) {HStack {Text(item.title).foregroundStyle(.secondary);Spacer();Text(item.value).monospacedDigit().textSelection(.enabled)};if let explanation=item.explanation {Text(explanation).font(.caption2).foregroundStyle(.secondary)}}.font(.system(size:12))}
            Button("Открыть платежи в \(snapshot.provider == .claude ? "Claude" : "ChatGPT") ↗"){model.openBilling(snapshot.provider)}.buttonStyle(.link)
            if !snapshot.activity.isEmpty {
                Text("Активность аккаунта · токены").font(.system(size:14,weight:.semibold))
                Chart(Array(snapshot.activity.suffix(14))) {day in BarMark(x:.value("Дата",String(day.day.suffix(5))),y:.value("Токены",day.tokens)).foregroundStyle(QuotaPalette.accent(.openai,scheme:scheme))}.frame(height:130)
                Text("Это статистика использования сервиса, а не сумма списания и не остаток подписки.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {Text(snapshot.source.isEmpty ? "Подключение не настроено" : snapshot.source);Spacer();Text(snapshot.observedAt.map {"Данные от "+$0.formatted(date:.abbreviated,time:.shortened)} ?? "Нет снимка")}.font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func connectionButtons(_ provider:Provider)->some View {
        HStack(spacing:8) {
            if provider == .openai {
                Button("Прочитать из Codex"){model.enableLocalRead(.openai)}
                Button("Войти через ChatGPT"){model.connectCodex()}.buttonStyle(.borderedProminent)
                if model.loginInProgress {Button("Отменить вход"){model.cancelCodexLogin()}}
            } else {
                Button("Сеанс Claude Desktop"){model.connectClaudeDesktop()}
                Button("Сеанс Claude Code"){model.connectClaudeLocal()}
                Button("Войти в Claude"){model.connectClaudeWeb()}.buttonStyle(.borderedProminent)
            }
            Spacer()
            Button("Отключить"){model.disconnect(provider)}.foregroundStyle(.secondary)
        }.controlSize(.small).disabled(model.refreshing.contains(provider))
    }
}

private struct SettingsView:View {
    @EnvironmentObject var model:AppModel
    @State private var launchAtLogin=SMAppService.mainApp.status == .enabled
    var body:some View {
        Form {
            Section("Приложение") {
                Toggle("Запускать при входе в macOS",isOn:$launchAtLogin).onChange(of:launchAtLogin) {_,enabled in
                    do {if enabled{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}}
                    catch {model.notice=error.localizedDescription;launchAtLogin=SMAppService.mainApp.status == .enabled}
                }
                Text("Quota обновляет данные каждые 5 минут, пока приложение запущено. macOS отдельно определяет частоту обновления виджетов.").font(.caption).foregroundStyle(.secondary)
                if let note=model.signingNote {Text(note).font(.caption).foregroundStyle(.secondary)}
            }
            Section("Codex") {
                Picker("Подключение",selection:Binding(get:{model.codexRoute},set:{model.selectCodexRoute($0)})) {
                    Text("Автоматически (включая ATLAS)").tag("auto")
                    Text("ChatGPT Proxy · ATLAS").tag("atlas")
                    Text("Обычный запуск").tag("direct")
                }
                Text(CodexConnection.executable()?.path ?? "Исполняемый файл не найден").font(.caption).textSelection(.enabled)
                Button("Выбрать исполняемый файл…"){model.chooseExecutable()}
                Text("Входом и обновлением сессии управляет установленный Codex. Quota не копирует его токены.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Конфиденциальность") {
                Text("Сеанс Claude хранится в Связке ключей. Виджет получает только снимок лимитов; пароли и токены в него не передаются. Отключение в Quota не завершает сессии установленных приложений.").font(.caption)
            }
        }.formStyle(.grouped).frame(width:520,height:450)
    }
}
