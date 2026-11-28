import SwiftUI

// MARK: - What the start page can show (order + visibility are user-editable, like Safari's "自定义起始页")

enum StartSection: String, CaseIterable, Identifiable {
    case favorites, frequent, news, offline, closed
    var id: String { rawValue }
    var title: String {
        switch self { case .favorites: "个人收藏"; case .frequent: "经常访问的网站"; case .news: "新闻"; case .offline: "离线可读"; case .closed: "最近关闭的标签页" }
    }
    var icon: String {
        switch self { case .favorites: "star"; case .frequent: "clock"; case .news: "newspaper"; case .offline: "arrow.down.circle"; case .closed: "square.on.square" }
    }
}

// MARK: - Flat background gallery (drawn in code: no assets, crisp at any size, follows light/dark)

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum StartBG: String, CaseIterable, Identifiable {
    case dunes, mountains, topo, terrazzo, bauhaus, ribbons, dusk, sunrise, meadow, waves, blocks, aurora
    var id: String { rawValue }
    var title: String {
        switch self { case .dunes: "沙丘"; case .mountains: "远山"; case .topo: "等高线"; case .terrazzo: "水磨石"; case .bauhaus: "包豪斯"; case .ribbons: "彩带"
                      case .dusk: "黄昏"; case .sunrise: "日出"; case .meadow: "草地"; case .waves: "海浪"; case .blocks: "方块"; case .aurora: "极光" }
    }
}

private func C(_ hex: UInt32, _ a: Double = 1) -> Color { Color(hex: hex, alpha: a) }

struct StartBackgroundView: View {
    let bg: StartBG
    var dark = false

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(s: UInt64(bg.hashValue & 0xFFFF) &+ 7)
            let w = size.width, h = size.height
            func rect() -> Path { Path(CGRect(origin: .zero, size: size)) }
            func wave(_ base: CGFloat, _ amp: CGFloat, _ freq: CGFloat, _ phase: CGFloat) -> Path {
                var p = Path(); p.move(to: CGPoint(x: 0, y: h))
                var x: CGFloat = 0
                while x <= w + 4 { p.addLine(to: CGPoint(x: x, y: h * base + sin(x / w * .pi * 2 * freq + phase) * h * amp)); x += 4 }
                p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath(); return p
            }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)) }
            func grad(_ a: Color, _ b: Color) -> GraphicsContext.Shading { .linearGradient(Gradient(colors: [a, b]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)) }

            switch bg {
            case .dunes:
                ctx.fill(rect(), with: grad(C(0xF7E7EE), C(0xE6DDF4)))
                ctx.fill(circle(w * 0.25, h * 0.2, w * 0.14), with: .color(C(0xFFF3F0, 0.9)))
                for (i, col) in [0xF6C9D6, 0xEBB9CF, 0xC9B6E8, 0xA99BDD].enumerated() { ctx.fill(wave(0.45 + CGFloat(i) * 0.14, 0.05, 1.3 + CGFloat(i) * 0.2, CGFloat(i) * 1.7), with: .color(C(UInt32(col)))) }
            case .mountains:
                ctx.fill(rect(), with: grad(C(0xC8D3F1), C(0xF1EAF3)))
                ctx.fill(circle(w * 0.3, h * 0.22, w * 0.11), with: .color(C(0xFFF6EA, 0.95)))
                let cols: [UInt32] = [0xAEBDE8, 0x8CA3E3, 0x5F83DD, 0x3F6BC4]
                for (i, col) in cols.enumerated() {
                    var p = Path(); let base = h * (0.42 + CGFloat(i) * 0.12); p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: base))
                    var x: CGFloat = 0
                    while x < w { x += CGFloat.random(in: 40...90, using: &rng); p.addLine(to: CGPoint(x: min(x, w), y: base - CGFloat.random(in: 20...(90 - CGFloat(i) * 12), using: &rng))) }
                    p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath(); ctx.fill(p, with: .color(C(col)))
                }
                ctx.fill(wave(0.86, 0.025, 1.6, 0.6), with: .color(C(0x3F7F6A)))
            case .topo:
                ctx.fill(rect(), with: .color(C(0xF3F0CC)))
                let pal: [UInt32] = [0xDDE8D2, 0xC9D8E8, 0xB4C3EC, 0xA3B2E8, 0xC9C4EE, 0xE9E4C0]
                for k in stride(from: 9, through: 0, by: -1) {
                    var p = Path(); let r = CGFloat(k + 1) * w * 0.09
                    for a in stride(from: 0.0, through: 2 * .pi + 0.1, by: 0.1) {
                        let rr = r * (1 + 0.16 * sin(a * 3 + Double(k) * 0.5) + 0.09 * cos(a * 5))
                        let pt = CGPoint(x: w * 0.42 + cos(a) * rr * 1.15, y: h * 0.45 + sin(a) * rr * 1.3)
                        if a == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath(); ctx.fill(p, with: .color(C(pal[k % pal.count])))
                }
            case .terrazzo:
                ctx.fill(rect(), with: .color(C(0xE2D6BE)))
                let pal: [UInt32] = [0xC9A27E, 0x8E9B8A, 0xD98E73, 0x6F8CA8, 0xF0C987, 0xA46A5B]
                for _ in 0..<130 {
                    let c = CGPoint(x: CGFloat.random(in: 0...w, using: &rng), y: CGFloat.random(in: 0...h, using: &rng)); let r = CGFloat.random(in: 5...16, using: &rng)
                    let col = pal[Int.random(in: 0..<pal.count, using: &rng)]
                    var p = Path(); let n = Int.random(in: 3...6, using: &rng); let rot = Double.random(in: 0...6, using: &rng)
                    for i in 0..<n { let a = rot + Double(i) / Double(n) * 2 * .pi; let rr = r * CGFloat.random(in: 0.6...1, using: &rng); let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
                    p.closeSubpath(); ctx.fill(p, with: .color(C(col)))
                }
            case .bauhaus:
                ctx.fill(rect(), with: .color(C(0xF2E9D8)))
                ctx.fill(circle(w * 0.68, h * 0.3, w * 0.3), with: .color(C(0x2F5BD3)))
                var half = Path(); half.addArc(center: CGPoint(x: w * 0.3, y: h * 0.72), radius: w * 0.26, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false); half.closeSubpath()
                ctx.fill(half, with: .color(C(0xE5533C)))
                var tri = Path(); tri.move(to: CGPoint(x: w * 0.62, y: h * 0.86)); tri.addLine(to: CGPoint(x: w * 0.9, y: h * 0.86)); tri.addLine(to: CGPoint(x: w * 0.76, y: h * 0.6)); tri.closeSubpath()
                ctx.fill(tri, with: .color(C(0xF2B632)))
                ctx.fill(Path(CGRect(x: w * 0.1, y: h * 0.12, width: w * 0.28, height: h * 0.05)), with: .color(C(0x1E1E24)))
                ctx.fill(circle(w * 0.2, h * 0.3, w * 0.05), with: .color(C(0x1E1E24)))
            case .ribbons:
                ctx.fill(rect(), with: .color(C(0x9CC7CF)))
                func poly(_ pts: [(CGFloat, CGFloat)], _ col: UInt32) { var p = Path(); p.move(to: CGPoint(x: pts[0].0 * w, y: pts[0].1 * h)); for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * w, y: q.1 * h)) }; p.closeSubpath(); ctx.fill(p, with: .color(C(col))) }
                poly([(0, 1), (0.55, 0), (1, 0), (1, 1)], 0x2C443C)
                poly([(0, 1), (0.45, 0.25), (0.78, 1)], 0x3858A6)
                poly([(0, 0.3), (0.48, 0), (0.62, 0), (0.2, 0.9), (0, 1)], 0xD9D5CC)
            case .dusk:
                ctx.fill(rect(), with: .linearGradient(Gradient(colors: [C(0xF4A261), C(0xE76F7B), C(0x7B5EA7), C(0x2E2A5C)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                ctx.fill(circle(w * 0.5, h * 0.4, w * 0.2), with: .color(C(0xFFE7B0, 0.9)))
                ctx.fill(wave(0.66, 0.03, 1.1, 0.4), with: .color(C(0x4B3B7A))); ctx.fill(wave(0.78, 0.04, 1.5, 2.0), with: .color(C(0x2E2A5C))); ctx.fill(wave(0.9, 0.03, 1.2, 4.0), with: .color(C(0x1B1940)))
            case .sunrise:
                ctx.fill(rect(), with: .linearGradient(Gradient(colors: [C(0x9EC3F2), C(0xF6D9C0), C(0xF9B68F)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.8)))
                ctx.fill(circle(w * 0.7, h * 0.52, w * 0.16), with: .color(C(0xFFF1D6)))
                ctx.fill(wave(0.62, 0.04, 1.0, 1.0), with: .color(C(0xE8A07A))); ctx.fill(wave(0.74, 0.05, 1.3, 3.0), with: .color(C(0xC77D68))); ctx.fill(wave(0.88, 0.04, 1.0, 5.0), with: .color(C(0x8E5A5E)))
            case .meadow:
                ctx.fill(rect(), with: .color(C(0x9BCB72)))
                for _ in 0..<260 {
                    let x = CGFloat.random(in: 0...w, using: &rng), y = CGFloat.random(in: 0...h, using: &rng); var p = Path()
                    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + CGFloat.random(in: -4...4, using: &rng), y: y - CGFloat.random(in: 6...13, using: &rng)))
                    ctx.stroke(p, with: .color(C([0x3E8A4A, 0x2F7A3E, 0x6FB05A][Int.random(in: 0...2, using: &rng)])), lineWidth: 2)
                }
            case .waves:
                ctx.fill(rect(), with: .color(C(0x6E9BE8)))
                let r: CGFloat = 38
                for row in 0..<Int(h / (r * 0.6)) + 2 {
                    for col in 0..<Int(w / (r * 2)) + 2 {
                        let cx = CGFloat(col) * r * 2 + (row % 2 == 0 ? 0 : r), cy = CGFloat(row) * r * 0.6
                        var p = Path(); p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                        ctx.stroke(p, with: .color(C(0xFFFFFF, 0.55)), lineWidth: 2.4)
                    }
                }
            case .blocks:
                ctx.fill(rect(), with: .color(C(0xF4EFE6)))
                let pal: [UInt32] = [0xF2C6B4, 0xB9D3E6, 0xC9E0C3, 0xF4E1A1, 0xD5C3E8, 0xE9ADAD]
                let s = w / 5
                for row in 0..<Int(h / s) + 1 { for col in 0..<5 where Bool.random(using: &rng) || (row + col) % 3 == 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: CGFloat(col) * s + 6, y: CGFloat(row) * s + 6, width: s - 12, height: s - 12), cornerRadius: s * 0.22), with: .color(C(pal[Int.random(in: 0..<pal.count, using: &rng)])))
                } }
            case .aurora:
                ctx.fill(rect(), with: .color(C(0xF6F1EA)))
                ctx.addFilter(.blur(radius: min(w, h) * 0.12))
                ctx.fill(circle(w * 0.2, h * 0.25, w * 0.4), with: .color(C(0xF4B7C9)))
                ctx.fill(circle(w * 0.85, h * 0.4, w * 0.38), with: .color(C(0xA9C4F5)))
                ctx.fill(circle(w * 0.4, h * 0.8, w * 0.42), with: .color(C(0xB6E8D0)))
                ctx.fill(circle(w * 0.9, h * 0.9, w * 0.3), with: .color(C(0xF9D9A6)))
            }
        }
        .overlay(Color.black.opacity(dark ? 0.38 : 0))
    }
}

// MARK: - Editor (Safari-style: toggles + drag handles + background gallery)

struct StartPageEditor: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private var order: [StartSection] {
        var o = settings.prefs.startOrder.compactMap(StartSection.init(rawValue:))
        for s in StartSection.allCases where !o.contains(s) { o.append(s) }
        return o
    }
    private func visible(_ s: StartSection) -> Binding<Bool> {
        Binding(get: { !settings.prefs.startHidden.contains(s.rawValue) },
                set: { on in
                    var h = settings.prefs.startHidden.filter { $0 != s.rawValue }
                    if !on { h.append(s.rawValue) }
                    withAnimation(Motion.snappy) { settings.prefs.startHidden = h }
                })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { s in
                        HStack(spacing: 14) {
                            Image(systemName: s.icon).font(.system(size: 19, weight: .regular)).foregroundStyle(theme.ink).frame(width: 28)
                            Text(s.title).font(.system(size: 17)).foregroundStyle(theme.ink)
                            Spacer()
                            Toggle("", isOn: visible(s)).labelsHidden()
                        }
                    }
                    .onMove { from, to in
                        var o = order.map(\.rawValue); o.move(fromOffsets: from, toOffset: to)
                        withAnimation(Motion.snappy) { settings.prefs.startOrder = o }
                    }
                }.listRowBackground(theme.surface)

                Section {
                    Toggle(isOn: Binding(get: { !settings.prefs.startBackground.isEmpty }, set: { on in
                        withAnimation(Motion.smooth) { settings.prefs.startBackground = on ? (StartBG(rawValue: settings.prefs.startBackground)?.rawValue ?? StartBG.dunes.rawValue) : "" }
                    })) { Label("背景图像", systemImage: "photo").foregroundStyle(theme.ink) }
                    if !settings.prefs.startBackground.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(StartBG.allCases) { b in
                                Button { Haptics.soft(); withAnimation(Motion.smooth) { settings.prefs.startBackground = b.rawValue } } label: {
                                    StartBackgroundView(bg: b, dark: theme.scheme == .dark)
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(settings.prefs.startBackground == b.rawValue ? theme.accent : .clear, lineWidth: 3))
                                        .overlay(alignment: .topTrailing) {
                                            if settings.prefs.startBackground == b.rawValue {
                                                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette).foregroundStyle(theme.inkSoft, .white).padding(6)
                                                    .onTapGesture { withAnimation(Motion.smooth) { settings.prefs.startBackground = "" } }
                                            }
                                        }
                                }.buttonStyle(PressableStyle(scale: 0.95))
                            }
                        }.padding(.vertical, 6)
                    }
                }.listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(theme.background.ignoresSafeArea())
            .environment(\.editMode, .constant(.active))
            .navigationTitle("自定义起始页").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }
}
