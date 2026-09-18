import SwiftUI

/// A capital Q formed by a quota ring and its diagonal tail. Entirely native vector geometry.
public struct QuotaAppIcon: View {
    public init() {}
    public var body:some View {
        GeometryReader { geometry in
            let unit=min(geometry.size.width,geometry.size.height)/100
            ZStack {
                RoundedRectangle(cornerRadius:22*unit,style:.continuous)
                    .fill(LinearGradient(colors:[Color(hex:0x303A32),Color(hex:0x202720)],startPoint:.topLeading,endPoint:.bottomTrailing))
                RoundedRectangle(cornerRadius:22*unit,style:.continuous)
                    .strokeBorder(Color.white.opacity(0.10),lineWidth:0.8*unit)
                Circle().stroke(Color(hex:0x536153),lineWidth:9*unit)
                    .frame(width:52*unit,height:52*unit).position(x:48*unit,y:47*unit)
                Circle().trim(from:0,to:0.73)
                    .stroke(Color(hex:0xC5DBC2),style:StrokeStyle(lineWidth:9*unit,lineCap:.round))
                    .rotationEffect(.degrees(-90))
                    .frame(width:52*unit,height:52*unit).position(x:48*unit,y:47*unit)
                Path {p in p.move(to:CGPoint(x:58*unit,y:59*unit));p.addLine(to:CGPoint(x:74*unit,y:76*unit))}
                    .stroke(Color(hex:0xC5DBC2),style:StrokeStyle(lineWidth:10*unit,lineCap:.round))
                Circle().fill(Color(hex:0xE4A78B)).frame(width:5*unit,height:5*unit)
                    .position(x:22.2*unit,y:50.3*unit)
            }
        }.aspectRatio(1,contentMode:.fit).accessibilityHidden(true)
    }
}
