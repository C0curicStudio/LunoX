import SwiftUI

struct TriangleShape: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p }
}
struct HalfCircle: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.addArc(center: CGPoint(x: r.midX, y: r.maxY), radius: r.width / 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false); p.closeSubpath(); return p }
}
struct DotGrid: View {
    var color: Color; var cols = 5; var rows = 4; var size: CGFloat = 5; var gap: CGFloat = 12
    var body: some View {
        VStack(spacing: gap) { ForEach(0..<rows, id: \.self) { _ in HStack(spacing: gap) { ForEach(0..<cols, id: \.self) { _ in Circle().fill(color).frame(width: size, height: size) } } } }
    }
}

private struct Floating: ViewModifier {
    var amp: CGFloat; var rot: Double; var dur: Double; var on: Bool; var delay: Double
    func body(content: Content) -> some View {
        content
            .offset(y: on ? -amp : amp)
            .rotationEffect(.degrees(on ? rot : -rot))
            .animation(.easeInOut(duration: dur).repeatForever(autoreverses: true).delay(delay), value: on)
    }
}
private extension View {
    func floating(_ amp: CGFloat, rot: Double = 0, dur: Double = 4, on: Bool, delay: Double = 0) -> some View { modifier(Floating(amp: amp, rot: rot, dur: dur, on: on, delay: delay)) }
}

/// Flat, geometric, softly drifting artwork in the current theme's colours (Bauhaus-ish, no gradients or blur).
struct FlatArt: View {
    let theme: Theme
    var seed = 0
    var animated = true
    @State private var on = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                switch seed % 3 {
                case 0:
                    Circle().fill(theme.shapeA).frame(width: h * 0.62).position(x: w * 0.80, y: h * 0.42).floating(6, dur: 5, on: on)
                    RoundedRectangle(cornerRadius: h * 0.08, style: .continuous).fill(theme.shapeB).frame(width: h * 0.36, height: h * 0.36)
                        .rotationEffect(.degrees(16)).position(x: w * 0.18, y: h * 0.62).floating(8, rot: 4, dur: 6, on: on, delay: 0.4)
                    TriangleShape().fill(theme.shapeC).frame(width: h * 0.26, height: h * 0.24).position(x: w * 0.52, y: h * 0.2).floating(5, rot: 6, dur: 4.5, on: on, delay: 0.8)
                    Capsule().fill(theme.shapeA.opacity(0.35)).frame(width: h * 0.5, height: h * 0.12).rotationEffect(.degrees(-28)).position(x: w * 0.3, y: h * 0.18).floating(4, dur: 5.5, on: on, delay: 0.2)
                    DotGrid(color: theme.inkSoft.opacity(0.35)).position(x: w * 0.62, y: h * 0.82).floating(3, dur: 7, on: on)
                case 1:
                    HalfCircle().fill(theme.shapeB).frame(width: h * 0.7, height: h * 0.35).position(x: w * 0.25, y: h * 0.78).floating(5, dur: 5, on: on)
                    Circle().fill(theme.shapeC).frame(width: h * 0.3).position(x: w * 0.7, y: h * 0.72).floating(7, dur: 4.2, on: on, delay: 0.5)
                    Circle().stroke(theme.shapeA, lineWidth: h * 0.07).frame(width: h * 0.5).position(x: w * 0.82, y: h * 0.28).floating(6, dur: 6, on: on, delay: 0.3)
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.shapeA).frame(width: h * 0.22, height: h * 0.22).rotationEffect(.degrees(-12)).position(x: w * 0.22, y: h * 0.3).floating(6, rot: 5, dur: 5.5, on: on, delay: 0.7)
                    DotGrid(color: theme.inkSoft.opacity(0.3), cols: 4, rows: 3).position(x: w * 0.5, y: h * 0.38).floating(3, dur: 6.5, on: on)
                default:
                    TriangleShape().fill(theme.shapeA).frame(width: h * 0.5, height: h * 0.46).position(x: w * 0.24, y: h * 0.58).floating(6, rot: 3, dur: 5.2, on: on)
                    Circle().fill(theme.shapeB).frame(width: h * 0.4).position(x: w * 0.62, y: h * 0.3).floating(7, dur: 4.6, on: on, delay: 0.3)
                    RoundedRectangle(cornerRadius: h * 0.1, style: .continuous).fill(theme.shapeC).frame(width: h * 0.34, height: h * 0.2).rotationEffect(.degrees(-10)).position(x: w * 0.82, y: h * 0.7).floating(5, rot: 4, dur: 5.8, on: on, delay: 0.6)
                    Circle().stroke(theme.shapeC, lineWidth: h * 0.05).frame(width: h * 0.26).position(x: w * 0.44, y: h * 0.82).floating(4, dur: 4.4, on: on, delay: 0.9)
                    DotGrid(color: theme.inkSoft.opacity(0.3), cols: 3, rows: 5).position(x: w * 0.9, y: h * 0.18).floating(3, dur: 7, on: on)
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
        .onAppear { if animated { on = true } }
    }
}
