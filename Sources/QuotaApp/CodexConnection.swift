import Foundation
import AppKit
import QuotaCore

@MainActor final class CodexConnection {
    private var process: Process?
    private var input: FileHandle?
    private var buffer=Data()
    private var nextID=0
    private var pending:[Int:CheckedContinuation<[String:Any],Error>]=[:]
    private var timeouts:[Int:Task<Void,Never>]=[:]
    private var initialization:Task<Void,Error>?
    private var activeProxy:LocalProxy?
    private(set) var loginID:String?
    var onLoginCompleted:((Bool)->Void)?

    static func executable() -> URL? {
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        let configured=UserDefaults.standard.string(forKey:"codexExecutable")
        let choices=[configured,"/Applications/ChatGPT.app/Contents/Resources/codex","/Applications/Codex.app/Contents/Resources/codex",
                     home+"/Applications/ChatGPT.app/Contents/Resources/codex",home+"/Applications/Codex.app/Contents/Resources/codex",home+"/.local/bin/codex","/opt/homebrew/bin/codex","/usr/local/bin/codex"].compactMap {$0}
        return choices.first(where:{FileManager.default.isExecutableFile(atPath:$0)}).map {URL(fileURLWithPath:$0)}
    }
    func start() async throws {
        if let initialization {try await initialization.value;return}
        let proxy=try LocalProfiles.codexProxy(mode:UserDefaults.standard.string(forKey:"codexRoute") ?? "auto")
        if process?.isRunning == true, activeProxy != proxy {stop()}
        if process?.isRunning == true {return}
        let task=Task { @MainActor [self] in
            guard let executable=Self.executable() else{throw QuotaError.message("Codex не найден. Установите ChatGPT/Codex или выберите исполняемый файл в настройках.")}
            let p=Process(),stdin=Pipe(),stdout=Pipe()
            p.executableURL=executable;p.arguments=["app-server","--stdio"]
            if let proxy {p.environment=proxy.environment(inheriting:ProcessInfo.processInfo.environment)}
            activeProxy=proxy
            p.standardInput=stdin;p.standardOutput=stdout;p.standardError=FileHandle.nullDevice
            let cwd=SnapshotStore.appDirectory().appendingPathComponent("CodexBridge",isDirectory:true)
            try FileManager.default.createDirectory(at:cwd,withIntermediateDirectories:true)
            p.currentDirectoryURL=cwd
            stdout.fileHandleForReading.readabilityHandler={ [weak self, weak p] handle in
                let data=handle.availableData
                Task {@MainActor [weak self, weak p] in guard let self, let p,self.process === p else{return};self.receive(data)}
            }
            p.terminationHandler={ [weak self] ended in Task {@MainActor [weak self] in guard let self,self.process === ended else{return};self.terminated()} }
            process=p;input=stdin.fileHandleForWriting
            do {try p.run()} catch {process=nil;input=nil;throw QuotaError.message("Не удалось запустить Codex: \(error.localizedDescription)")}
            _=try await self.request("initialize",params:["clientInfo":["name":"quota","title":"Quota","version":"1.0.0"],"capabilities":["experimentalApi":true]])
            try self.send(["method":"initialized","params":[:]])
        }
        initialization=task
        do {try await task.value;initialization=nil} catch {initialization=nil;stop();throw error}
    }
    func fetch() async throws -> ProviderSnapshot {
        try await start()
        let account=try await request("account/read",params:["refreshToken":false])
        guard let info=account["account"] as? [String:Any] else{throw QuotaError.authentication("В Codex нет активной сессии. Войдите через ChatGPT.")}
        guard (info["type"] as? String)?.lowercased().contains("chatgpt") == true else {
            throw QuotaError.authentication("Codex подключён без подписки ChatGPT. Для её лимитов войдите через ChatGPT.")
        }
        let limits=try await request("account/rateLimits/read")
        let usage=try? await request("account/usage/read")
        var snapshot=CodexParser.parse(account:account,limits:limits,usage:usage)
        if activeProxy != nil {snapshot.source += " · ATLAS"}
        if usage == nil {snapshot.metrics.append(.init("usage-unavailable","История использования","Не предоставлена этой версией Codex"))}
        return snapshot
    }
    func login() async throws {
        try await start()
        if let loginID {_=try? await request("account/login/cancel",params:["loginId":loginID]);self.loginID=nil}
        let result=try await request("account/login/start",params:["type":"chatgpt"])
        guard let value=result["authUrl"] as? String,let url=URL(string:value),url.scheme == "https",
              ["auth.openai.com","chatgpt.com","auth0.openai.com"].contains(url.host?.lowercased() ?? "") else {
            throw QuotaError.message("Codex не вернул допустимую ссылку входа.")
        }
        loginID=result["loginId"] as? String
        NSWorkspace.shared.open(url)
    }
    func cancelLogin() async {if let loginID {_=try? await request("account/login/cancel",params:["loginId":loginID])};loginID=nil}
    func stop() {
        process?.terminationHandler=nil
        if let out=process?.standardOutput as? Pipe {out.fileHandleForReading.readabilityHandler=nil}
        try? input?.close();input=nil
        if process?.isRunning == true {process?.terminate()}
        process=nil;buffer.removeAll();failPending(QuotaError.message("Соединение с Codex закрыто."))
    }
    private func terminated() {process=nil;input=nil;buffer.removeAll();failPending(QuotaError.message("Codex завершил соединение. Повторите обновление."))}
    private func failPending(_ error: Error) {
        let waiting=pending;pending.removeAll();timeouts.values.forEach {$0.cancel()};timeouts.removeAll()
        waiting.values.forEach {$0.resume(throwing:error)}
    }
    private func request(_ method: String, params: [String:Any] = [:]) async throws -> [String:Any] {
        nextID += 1;let id=nextID
        return try await withCheckedThrowingContinuation {continuation in
            pending[id]=continuation
            timeouts[id]=Task { @MainActor [weak self] in
                do {try await Task.sleep(nanoseconds:25_000_000_000)}catch{return}
                guard let self else{return};self.timeouts.removeValue(forKey:id)
                let help=self.activeProxy == nil ? "" : " Проверьте, что ChatGPT Proxy (ATLAS) и его туннель запущены."
                self.pending.removeValue(forKey:id)?.resume(throwing:QuotaError.message("Codex не ответил за 25 секунд.\(help)"))
            }
            do {try send(["method":method,"id":id,"params":params])}
            catch {pending.removeValue(forKey:id)?.resume(throwing:error);timeouts.removeValue(forKey:id)?.cancel()}
        }
    }
    private func send(_ object:[String:Any]) throws {
        guard let input,process?.isRunning == true else{throw QuotaError.message("Codex не запущен.")}
        var data=try JSONSerialization.data(withJSONObject:object);data.append(10);try input.write(contentsOf:data)
    }
    private func receive(_ data:Data) {
        guard !data.isEmpty else{return};buffer.append(data)
        guard buffer.count<16_000_000 else{stop();return}
        while let newline=buffer.firstIndex(of:10) {
            let line=buffer.subdata(in:0..<newline);buffer.removeSubrange(0...newline)
            guard let object=try? JSONSerialization.jsonObject(with:line) as? [String:Any] else{continue}
            if let method=object["method"] as? String {
                if let id=object["id"] {try? send(["id":id,"error":["code":-32601,"message":"Unsupported method"]])}
                else if method == "account/login/completed",let params=object["params"] as? [String:Any] {
                    loginID=nil;onLoginCompleted?(params["success"] as? Bool == true)
                }
                continue
            }
            guard let id=object["id"] as? Int,let waiting=pending.removeValue(forKey:id) else{continue}
            timeouts.removeValue(forKey:id)?.cancel()
            if let error=object["error"] as? [String:Any] {
                let code=error["code"] as? Int ?? 0
                let message=(error["message"] as? String ?? "").lowercased()
                if message.contains("unauthorized") || message.contains("not authenticated") || message.contains("not logged in") {
                    waiting.resume(throwing:QuotaError.authentication("Сессия Codex закончилась. Войдите через ChatGPT."));continue
                }
                // No raw server text in logs or UI: it may contain account details.
                let help=activeProxy == nil ? "Проверьте вход и повторите запрос." : "Проверьте, что ChatGPT Proxy (ATLAS) запущен и его туннель работает."
                waiting.resume(throwing:QuotaError.message("Codex не предоставил данные (код \(code)). \(help)"))
            } else {waiting.resume(returning:object["result"] as? [String:Any] ?? [:])}
        }
    }
}
