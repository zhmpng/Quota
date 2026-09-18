import AppKit
import SwiftUI
import WebKit
import Network
import QuotaCore

@MainActor final class ClaudeLoginWindow:NSObject,ObservableObject,WKNavigationDelegate,WKUIDelegate {
    @Published var status="Войдите на странице Claude. Пароль получает только Claude."
    @Published var ready=false
    let webView:WKWebView
    private var window:NSWindow!
    private var popups:[NSWindow]=[]
    private var timer:Timer?
    private var session:String?
    private let onSession:(String)->Void
    init(proxy:LocalProxy?=nil,onSession:@escaping(String)->Void) {
        self.onSession=onSession
        let config=WKWebViewConfiguration();config.websiteDataStore = .default()
        config.websiteDataStore.proxyConfigurations=proxy.map {[$0.configuration]} ?? []
        self.webView=WKWebView(frame:.zero,configuration:config)
        super.init();webView.navigationDelegate=self;webView.uiDelegate=self
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:750),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Подключение Claude · Quota";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:ClaudeLoginContent(controller:self));window.center()
    }
    func show() {
        if webView.url == nil {webView.load(URLRequest(url:URL(string:"https://claude.ai/login")!))}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            Task {@MainActor [weak self] in guard let self else{return};if !self.window.isVisible {self.timer?.invalidate();return};self.checkSession()}
        }
    }
    func complete() {guard let session else{return};onSession(session);timer?.invalidate();window.orderOut(nil);popups.forEach {$0.close()};popups.removeAll()}
    func close() {timer?.invalidate();webView.stopLoading();window.close();popups.forEach {$0.close()};popups.removeAll()}
    func clearSession() {
        session=nil;ready=false;webView.stopLoading();timer?.invalidate()
        let store=webView.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes()) {records in
            let selected=records.filter {$0.displayName.contains("claude") || $0.displayName.contains("anthropic")}
            store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),for:selected) {}
        }
    }
    private func checkSession() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task {@MainActor [weak self] in
                guard let self else{return}
                let cookie=cookies.first {$0.name == "sessionKey" && ["claude.ai",".claude.ai"].contains($0.domain.lowercased()) && ($0.expiresDate ?? .distantFuture)>Date()}
                self.session=cookie?.value;self.ready=cookie != nil
                if self.ready {self.status="Сессия найдена. Нажмите «Подключить», чтобы читать лимиты этого аккаунта."}
            }
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {checkSession()}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {status="Не удалось открыть страницу: \(error.localizedDescription)"}
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        guard navigationAction.targetFrame == nil else{return nil}
        let popup=WKWebView(frame:.zero,configuration:configuration);popup.uiDelegate=self;popup.navigationDelegate=self
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title="Вход Claude";w.isReleasedWhenClosed=false;w.contentView=popup;w.center();w.makeKeyAndOrderFront(nil);popups.append(w);return popup
    }
    func webViewDidClose(_ webView:WKWebView) {popups.first(where:{$0.contentView === webView})?.close();checkSession()}
}

private struct ClaudeLoginContent:View {
    @ObservedObject var controller:ClaudeLoginWindow
    var body:some View {
        VStack(spacing:0) {
            HStack {Text(controller.status).font(.system(size:12));Spacer();Button("Подключить"){controller.complete()}.buttonStyle(.borderedProminent).disabled(!controller.ready)}.padding(16)
            Divider();ClaudeWebView(webView:controller.webView)
            Text("Если провайдер входа блокирует встроенное окно, используйте сеанс Claude Code. Quota не обходит проверки входа.")
                .font(.system(size:11)).foregroundStyle(.secondary).padding(12)
        }.frame(minWidth:660,minHeight:540)
    }
}
private struct ClaudeWebView:NSViewRepresentable {
    let webView:WKWebView
    func makeNSView(context:Context)->WKWebView {webView}
    func updateNSView(_ nsView:WKWebView,context:Context) {}
}
