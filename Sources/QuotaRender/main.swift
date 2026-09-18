import Foundation
import AppKit
import SwiftUI
import WidgetKit
import QuotaCore
import QuotaUI

@main struct RenderQuota {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {print("Usage: QuotaRender OUTPUT_DIRECTORY");return}
        _=NSApplication.shared
        let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let now=Date(),dashboard=DemoData.make(now:now)
        let variants:[(Provider?,Bool)]=[(.claude,false),(.openai,false),(nil,true),(nil,false)]
        let modes:[(String,WidgetRenderingMode)]=[("color",.fullColor),("accented",.accented),("vibrant",.vibrant)]
        for dark in [false,true] {for (name,mode) in modes {for (provider,compact) in variants {
            let scheme:ColorScheme=dark ? .dark : .light
            let view=QuotaWidgetCard(dashboard:dashboard,provider:provider,compact:compact,now:now,linksEnabled:false)
                .frame(width:provider == nil && !compact ? 360 : 170,height:170)
                .background(QuotaPalette.surface(scheme),in:RoundedRectangle(cornerRadius:22))
                .environment(\.colorScheme,scheme).environment(\.widgetRenderingMode,mode)
            let variant=provider?.rawValue ?? (compact ? "combined-small" : "combined")
            let filename="native-\(variant)-\(dark ? "dark" : "light")-\(name)@2x.png"
            try save(view,to:directory.appendingPathComponent(filename),scale:2)
        }}}
        var missing=dashboard;missing.replace(.init(provider:.claude))
        try save(QuotaWidgetCard(dashboard:missing,now:now,linksEnabled:false)
            .frame(width:360,height:170).background(Color.black,in:RoundedRectangle(cornerRadius:22))
            .environment(\.colorScheme,.dark).environment(\.widgetRenderingMode,.accented),
            to:directory.appendingPathComponent("native-missing-monochrome@2x.png"),scale:2)
        try save(QuotaAppIcon().frame(width:900,height:900).padding(62),to:directory.appendingPathComponent("app-icon-1024.png"),scale:1)
        for dark in [false,true] {
            try save(DocumentationHero(dashboard:dashboard,now:now,dark:dark),
                to:directory.appendingPathComponent("readme-hero-\(dark ? "dark" : "light").png"),scale:1.5)
        }

        // Pixel regression: identical RGB tints must not make the empty rail look full.
        var checks:[[String:Any]]=[]
        for (name,mode) in modes where mode != .fullColor {
            let values:[Double?]=[0,1,20,64,100,nil]
            for value in values {
                let bar=RemainingBar(value:value,accent:.green,track:.gray)
                    .frame(width:200,height:6).padding(10).background(Color.black)
                    .environment(\.colorScheme,.dark).environment(\.widgetRenderingMode,mode)
                let renderer=ImageRenderer(content:bar);renderer.scale=1
                guard let image=renderer.cgImage else{throw QuotaError.message("Bar renderer failed")}
                let pixels=NSBitmapImageRep(cgImage:image)
                func brightness(_ x:Int)->Double {
                    guard let c=pixels.colorAt(x:x+10,y:13)?.usingColorSpace(.deviceRGB) else{return -1}
                    return (c.redComponent+c.greenComponent+c.blueComponent)/3
                }
                if let value {
                    let filled=Int(200*value/100)
                    if filled>4 {guard brightness(max(2,filled/2))>0.8 else{throw QuotaError.message("Monochrome fill lost contrast")}}
                    if filled<195 {guard brightness(max(filled+2,190))<0.35 else{throw QuotaError.message("Monochrome rail incorrectly looks full")}}
                } else {guard brightness(100)<0.1 else{throw QuotaError.message("Unknown quota incorrectly looks full")}}
                checks.append(["mode":name,"remaining":value.map {String($0)} ?? "unknown","passed":true])
            }
        }
        try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("monochrome-checks.json"))
        print("Rendered 4 layouts × 2 themes × 3 WidgetKit modes; 12 pixel checks passed.")
    }
    @MainActor private static func save<V:View>(_ view:V,to url:URL,scale:CGFloat) throws {
        let renderer=ImageRenderer(content:view);renderer.scale=scale
        guard let image=renderer.cgImage,let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw QuotaError.message("Не удалось отрисовать PNG.")}
        try data.write(to:url)
    }
}

/// README artwork uses the shipping SwiftUI views and synthetic data only.
private struct DocumentationHero:View {
    let dashboard:DashboardSnapshot
    let now:Date
    let dark:Bool
    private var scheme:ColorScheme {dark ? .dark : .light}
    private var foreground:Color {dark ? Color(hex:0xF0F2EC) : Color(hex:0x233C32)}
    var body:some View {
        HStack(alignment:.center,spacing:42) {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:17) {
                    QuotaAppIcon().frame(width:76,height:76)
                    Text("Quota").font(.system(size:52,weight:.semibold)).tracking(-2)
                }
                Text("Лимиты подписок.\nВсегда на виду.")
                    .font(.system(size:37,weight:.medium)).tracking(-1.2).lineSpacing(2).padding(.top,36)
                Text("Claude и ChatGPT / Codex\nв виджетах на рабочем столе macOS.")
                    .font(.system(size:17)).lineSpacing(6).opacity(0.75).padding(.top,18)
                HStack(spacing:9) {
                    Text("macOS 14+");Text("·");Text("SwiftUI");Text("·");Text("WidgetKit")
                }.font(.system(size:12,weight:.medium)).opacity(0.64).padding(.top,40)
            }.frame(width:382,alignment:.leading)
            VStack(spacing:29) {
                HStack(spacing:18) {
                    card(.openai,title:"Codex · 1 × 1")
                    card(.claude,title:"Claude · 1 × 1")
                    card(nil,compact:true,title:"Вместе · 1 × 1")
                }
                card(nil,title:"Вместе · 1 × 2")
            }.frame(width:546)
        }.foregroundStyle(foreground).padding(.horizontal,64)
            .frame(width:1120,height:588)
            .background(LinearGradient(colors:dark ? [Color(hex:0x122D28),Color(hex:0x243B32),Color(hex:0x444A37)] : [Color(hex:0xD6E3D5),Color(hex:0xECE9D9),Color(hex:0xD5DABF)],startPoint:.topLeading,endPoint:.bottomTrailing))
            .overlay(alignment:.bottomTrailing) {Text("ПРЕВЬЮ · ДЕМО-ДАННЫЕ").font(.system(size:9,weight:.medium)).tracking(1.3).foregroundStyle(foreground.opacity(0.5)).padding(22)}
    }
    private func card(_ provider:Provider?,compact:Bool=false,title:String)->some View {
        VStack(spacing:11) {
            QuotaWidgetCard(dashboard:dashboard,provider:provider,compact:compact,now:now,linksEnabled:false)
                .frame(width:provider == nil && !compact ? 360 : 170,height:170)
                .background(QuotaPalette.surface(scheme),in:RoundedRectangle(cornerRadius:22))
                .environment(\.colorScheme,scheme).environment(\.widgetRenderingMode,.fullColor)
                .shadow(color:.black.opacity(dark ? 0.22 : 0.12),radius:16,x:0,y:8)
            Text(title).font(.system(size:11,weight:.medium)).opacity(0.74)
        }
    }
}
