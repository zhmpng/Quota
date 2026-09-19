import AppKit
import Combine
import WidgetKit
import QuotaCore

@MainActor final class AppModel:ObservableObject {
    @Published var dashboard=DashboardSnapshot() {didSet {island.update(dashboard)}}
    @Published var refreshing:Set<Provider>=[]
    @Published var notice:String?
    @Published var selectedProvider:Provider = .openai
    @Published var organizations:[ClaudeOrganization]=[]
    @Published var organizationID=UserDefaults.standard.string(forKey:"claudeOrganization") ?? ""
    @Published var signingNote:String?
    @Published var loginInProgress=false
    @Published var claudeProfiles=LocalProfiles.claude()
    @Published var claudeProfileID=UserDefaults.standard.string(forKey:"claudeDesktopProfile") ?? "auto"
    @Published var codexRoute=UserDefaults.standard.string(forKey:"codexRoute") ?? "auto"
    let codex=CodexConnection()
    let island=DynamicIslandController()
    private var timer:Task<Void,Never>?
    private var started=false
    private var revisions:[Provider:Int]=[:]
    private var wakeObserver:NSObjectProtocol?
    private var loginWindow:ClaudeLoginWindow?
    private let persistenceQueue=DispatchQueue(label:"local.quota.snapshot",qos:.utility)

    func start() {
        guard !started else{return};started=true
        dashboard=SnapshotStore.load(from:SnapshotStore.appDirectory())
        island.start()
        // Older versions offered only the CLI button. Retry a failed, never-connected
        // CLI selection as Desktop when upgrading an ATLAS installation.
        if UserDefaults.standard.string(forKey:"claudeSource") == "local",
           dashboard.snapshot(.claude).observedAt == nil,claudeProfiles.contains(where: \.isAtlas) {
            UserDefaults.standard.set("auto",forKey:"claudeSource")
        }
        if SnapshotStore.systemWidgetsEnabled {Task {await WidgetRegistration.updateIfNeeded()}}
        codex.onLoginCompleted={ [weak self] success in
            guard let self else{return};self.loginInProgress=false
            if success {self.notice="Вход выполнен. Читаем лимиты подписки.";Task {await self.refresh(.openai)}}
            else {self.notice="Вход не завершён. Можно повторить подключение."}
        }
        wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task {@MainActor [weak self] in await self?.refreshAll()}
        }
        timer=Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:300_000_000_000)}catch{break}
                await self?.refreshAll()
            }
        }
        if !SnapshotStore.systemWidgetsEnabled {signingNote="Для системных виджетов нужна сборка с вашей подписью Apple Development и включённым App Group (см. README)."}
    }
    func refreshAll() async {await withTaskGroup(of:Void.self) {group in for p in Provider.allCases {group.addTask {@MainActor [weak self] in await self?.refresh(p)}}}}
    func refresh(_ provider:Provider, promptKeychain:Bool=false) async {
        guard !refreshing.contains(provider) else{return}
        let previous=dashboard.snapshot(provider)
        if let retry=previous.retryAfter,retry>Date() {notice="Пауза до \(retry.formatted(date:.omitted,time:.shortened)). Сервис попросил подождать.";return}
        if UserDefaults.standard.bool(forKey:"disabled-\(provider.rawValue)") {return}
        refreshing.insert(provider)
        let revision=(revisions[provider] ?? 0)+1;revisions[provider]=revision
        defer {refreshing.remove(provider)}
        do {
            var snapshot:ProviderSnapshot
            if provider == .openai {snapshot=try await codex.fetch()}
            else {
                snapshot=try await fetchClaude(promptKeychain:promptKeychain,revision:revision)
            }
            guard revisions[provider] == revision else{return}
            snapshot.selectedWindowID=UserDefaults.standard.string(forKey:"window-\(provider.rawValue)")
            snapshot.lastAttemptAt=Date();dashboard.replace(snapshot);persist()
        } catch {
            guard revisions[provider] == revision else{return}
            var failed=previous;failed.lastAttemptAt=Date();failed.message=error.localizedDescription
            if case QuotaError.authentication=error {failed.state = previous.observedAt == nil ? .disconnected : .reauth;failed.windows=[];failed.money=[];failed.metrics=[];failed.activity=[];failed.accountLabel=nil}
            else if case QuotaError.rateLimited(let retry)=error {failed.state = .rateLimited;failed.retryAfter=retry ?? Date().addingTimeInterval(600)}
            else {failed.state=failed.windows.isEmpty ? .unavailable : .offline}
            dashboard.replace(failed);persist()
        }
    }
    private func fetchClaude(promptKeychain:Bool,revision:Int) async throws -> ProviderSnapshot {
        claudeProfiles=LocalProfiles.claude()
        let mode=UserDefaults.standard.string(forKey:"claudeSource") ?? "auto"
        let profile=try LocalProfiles.selectedClaude(claudeProfiles,id:claudeProfileID)
        let proxy=try profile?.validatedProxy()
        if mode == "local" {return try await ClaudeConnection.fetchLocal(allowPrompt:promptKeychain,proxy:proxy)}
        // Preserve existing CLI connections on ordinary installations. ATLAS's isolated
        // Desktop account always wins in auto mode; do not fall through to another account.
        if mode == "auto",profile?.isAtlas != true,claudeProfileID == "auto",
           (try? ClaudeConnection.localCredentials(allowPrompt:false)) != nil {
            return try await ClaudeConnection.fetchLocal(allowPrompt:promptKeychain,proxy:proxy)
        }
        let session:String, source:String?, context:String
        if mode != "web", let profile {
            session=try await Task.detached {try ClaudeDesktopConnection.session(profile:profile,allowPrompt:promptKeychain)}.value
            source="Claude Desktop · \(profile.title)";context=profile.id
        } else if mode == "desktop" {
            throw QuotaError.authentication("Профиль Claude Desktop не найден. Запустите Claude через свой ярлык и нажмите «Обновить».")
        } else if let stored=try ClaudeConnection.webSession() {
            session=stored;source=nil;context="web"
        } else if mode == "auto" {
            return try await ClaudeConnection.fetchLocal(allowPrompt:promptKeychain,proxy:proxy)
        } else {throw QuotaError.authentication("Войдите в Claude или подключите сеанс Claude Desktop.")}
        let list=try await ClaudeConnection.organizations(session:session,proxy:proxy)
        guard revisions[.claude] == revision else {throw CancellationError()}
        organizations=list
        let saved=UserDefaults.standard.string(forKey:"claudeOrganization-\(context)") ?? ""
        let picked=list.first(where:{$0.id == saved}) ?? (list.count == 1 ? list.first : nil)
        guard let picked else{throw QuotaError.message(list.isEmpty ? "Claude не вернул доступные организации." : "Выберите организацию Claude ниже и обновите данные.")}
        organizationID=picked.id;UserDefaults.standard.set(picked.id,forKey:"claudeOrganization-\(context)")
        return try await ClaudeConnection.fetchWeb(session:session,organization:picked,proxy:proxy,source:source)
    }
    func selectOrganization(_ id:String) {
        organizationID=id
        let mode=UserDefaults.standard.string(forKey:"claudeSource") ?? "auto"
        let profile=try? LocalProfiles.selectedClaude(claudeProfiles,id:claudeProfileID)
        let context=mode == "web" ? "web" : profile?.id ?? "web"
        UserDefaults.standard.set(id,forKey:"claudeOrganization-\(context)")
        Task {await refresh(.claude)}
    }
    private func reconnect(_ provider:Provider,promptKeychain:Bool=false) {
        revisions[provider,default:0] += 1
        UserDefaults.standard.set(false,forKey:"disabled-\(provider.rawValue)")
        dashboard.replace(.init(provider:provider,state:.loading));persist()
        if provider == .claude {organizations=[];organizationID=""}
        Task {
            while refreshing.contains(provider) {try? await Task.sleep(nanoseconds:100_000_000)}
            await refresh(provider,promptKeychain:promptKeychain)
        }
    }
    func selectClaudeProfile(_ id:String) {
        claudeProfileID=id;UserDefaults.standard.set(id,forKey:"claudeDesktopProfile")
        UserDefaults.standard.set("desktop",forKey:"claudeSource")
        loginWindow?.close();loginWindow=nil
        reconnect(.claude)
    }
    func selectCodexRoute(_ route:String) {
        codexRoute=route;UserDefaults.standard.set(route,forKey:"codexRoute")
        codex.stop();reconnect(.openai)
    }
    func selectWindow(_ id:String,for provider:Provider) {var s=dashboard.snapshot(provider);s.selectedWindowID=id;dashboard.replace(s);UserDefaults.standard.set(id,forKey:"window-\(provider.rawValue)");persist()}
    func connectCodex() {UserDefaults.standard.set(false,forKey:"disabled-openai");Task {do {try await codex.login();loginInProgress=true;notice="Завершите вход в браузере. Приложение обновится автоматически."}catch{notice=error.localizedDescription}}}
    func cancelCodexLogin() {Task {await codex.cancelLogin();loginInProgress=false}}
    func connectClaudeLocal() {
        UserDefaults.standard.set("local",forKey:"claudeSource");reconnect(.claude,promptKeychain:true)
    }
    func connectClaudeDesktop() {
        UserDefaults.standard.set("desktop",forKey:"claudeSource");reconnect(.claude,promptKeychain:true)
    }
    func connectClaudeWeb() {
        UserDefaults.standard.set(false,forKey:"disabled-claude")
        if let loginWindow {loginWindow.show();return}
        let proxy:LocalProxy?
        do {claudeProfiles=LocalProfiles.claude();proxy=try LocalProfiles.selectedClaude(claudeProfiles,id:claudeProfileID)?.validatedProxy()}
        catch {notice=error.localizedDescription;return}
        let window=ClaudeLoginWindow(proxy:proxy) { [weak self] session in
            guard let self else{return}
            do {try QuotaKeychain.saveWebSession(session);UserDefaults.standard.set("web",forKey:"claudeSource");self.reconnect(.claude);self.notice="Claude подключён. Читаем доступные лимиты."}
            catch {self.notice=error.localizedDescription}
        }
        loginWindow=window;window.show()
    }
    func disconnect(_ provider:Provider) {
        revisions[provider,default:0] += 1
        UserDefaults.standard.set(true,forKey:"disabled-\(provider.rawValue)")
        if provider == .claude {QuotaKeychain.removeWebSession();loginWindow?.clearSession();organizations=[];organizationID="";UserDefaults.standard.removeObject(forKey:"claudeOrganization")}
        dashboard.replace(.init(provider:provider));persist()
        notice="Подключение отключено в Quota. Аккаунт в установленном приложении сохранён."
    }
    func enableLocalRead(_ provider:Provider) {UserDefaults.standard.set(false,forKey:"disabled-\(provider.rawValue)");Task {await refresh(provider)}}
    func chooseExecutable() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;panel.message="Выберите исполняемый файл codex"
        if panel.runModal() == .OK,let url=panel.url,FileManager.default.isExecutableFile(atPath:url.path) {
            UserDefaults.standard.set(url.path,forKey:"codexExecutable");codex.stop();enableLocalRead(.openai)
        }
    }
    func openBilling(_ provider:Provider) {NSWorkspace.shared.open(URL(string:provider == .claude ? "https://claude.ai/settings/billing" : "https://chatgpt.com/#settings/Account")!)}
    func shutdown() {timer?.cancel();island.stop();codex.stop();if let wakeObserver {NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)}}
    private func persist() {
        let snapshot=dashboard
        // Keep disk access off the UI actor, and preserve write order between providers.
        persistenceQueue.async { [weak self] in
            do {
                try SnapshotStore.persist(snapshot)
                if SnapshotStore.systemWidgetsEnabled {WidgetCenter.shared.reloadAllTimelines()}
            } catch {
                let message=error.localizedDescription
                Task {@MainActor [weak self] in self?.notice="Не удалось сохранить снимок: \(message)"}
            }
        }
    }
}
