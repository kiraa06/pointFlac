#if DEBUG
    import SwiftUI
    import UIKit

    /// Realistic stand-in cover art for the pressing gallery (`-PFGalleryRealCovers`): the fixture albums carry no art,
    /// so every wedge would otherwise be a generated sleeve. Ten covers in the styles real sleeves come in (bold type,
    /// a face, photographic gradients, a stark minimal one, a busy collage), drawn once with `ImageRenderer` and served
    /// to `ArtworkLoader` through its `source`, under their own album IDs, so they load exactly as stored covers do.
    @MainActor
    enum GalleryCovers {
        /// The stand-in albums, in the mockup's order: Paper Moons, Ignition, Night Drive, Low Tide, North Light,
        /// Tessellate, Saffron, Verdigris, Cathedral FM, Small Hours.
        static let ids = (0..<10).map { "pf-gallery-cover-\($0)" }

        static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-PFGalleryRealCovers") }

        private static var installed = false

        /// Renders the covers and serves them ahead of the library's own source. Call before any gallery view
        /// appears, so no cover is first looked up (and remembered as missing) without them.
        static func install() {
            guard !installed else { return }
            installed = true
            var covers: [String: Data] = [:]
            for (index, id) in ids.enumerated() {
                let renderer = ImageRenderer(content: GalleryCover(index: index).frame(width: 300, height: 300))
                renderer.scale = 2
                if let png = renderer.uiImage?.pngData() { covers[id] = png }
            }
            let served = covers
            let library = ArtworkLoader.shared.source
            ArtworkLoader.shared.source = { id in served[id] ?? library?(id) }
        }
    }

    /// One stand-in cover, 300 pt square.
    private struct GalleryCover: View {
        let index: Int

        var body: some View {
            ZStack {
                switch index {
                case 0: sunset
                case 1: ignition
                case 2: nightDrive
                case 3: lowTide
                case 4: northLight
                case 5: tessellate
                case 6: saffron
                case 7: verdigris
                case 8: cathedral
                default: smallHours
                }
            }
            .frame(width: 300, height: 300)
            .clipped()
        }

        private func hex(_ value: UInt32) -> Color { Color(deckHex: value) }

        /// Paper Moons: a photographic sunset over the sea, the sun cut by bands at the horizon.
        private var sunset: some View {
            ZStack {
                LinearGradient(
                    colors: [hex(0x2B1B4F), hex(0x8E3B6E), hex(0xF0745A), hex(0xFFC27A)], startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.62))
                Circle()
                    .fill(LinearGradient(colors: [hex(0xFFF1B0), hex(0xFF9E4F)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 150, height: 150)
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 86)
                            ForEach(0..<6) { k in
                                Rectangle().frame(height: 6 - CGFloat(k) * 0.7)
                                Color.clear.frame(height: 3 + CGFloat(k) * 1.2)
                            }
                            Spacer()
                        }
                    }
                    .offset(y: -20)
                LinearGradient(colors: [hex(0x3D2A6B), hex(0x120B2A)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 112)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                VStack(spacing: 7) {
                    ForEach(0..<9) { k in
                        Capsule().fill(hex(0xFFB36B).opacity(0.5 - Double(k) * 0.05))
                            .frame(width: 120 - CGFloat(k) * 11, height: 2)
                    }
                }
                .offset(y: 120)
                VStack {
                    Text("ADA VALE").font(.system(size: 15, weight: .semibold)).tracking(6)
                    Spacer()
                    Text("PAPER MOONS").font(.system(size: 13, weight: .medium)).tracking(5)
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.vertical, 18)
            }
        }

        /// Ignition: heavy type filling the sleeve.
        private var ignition: some View {
            ZStack(alignment: .topLeading) {
                hex(0x0E0E10)
                VStack(alignment: .leading, spacing: -22) {
                    Text("IGNI").font(.system(size: 118, weight: .black)).foregroundStyle(hex(0xFF4A1C))
                    Text("TION").font(.system(size: 118, weight: .black)).foregroundStyle(hex(0xFFB01F))
                }
                .tracking(-6)
                .padding(.leading, 6)
                .padding(.top, 8)
                Text("LUMEN ARCADE")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(3)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }

        /// Night Drive: a synthwave road to the horizon under a striped sun.
        private var nightDrive: some View {
            ZStack {
                LinearGradient(
                    colors: [hex(0x12002B), hex(0x5A0B6E), hex(0xFF3E9A)], startPoint: .top, endPoint: .center)
                Canvas { context, size in
                    let horizon = size.height * 0.55
                    context.fill(
                        Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
                        with: .color(hex(0x0B0018)))
                    var grid = Path()
                    for i in -10...10 {
                        grid.move(to: CGPoint(x: size.width / 2, y: horizon))
                        grid.addLine(to: CGPoint(x: size.width / 2 + CGFloat(i) * 60, y: size.height))
                    }
                    var y = horizon + 2
                    var step: CGFloat = 3
                    while y < size.height {
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                        step *= 1.35
                        y += step
                    }
                    context.stroke(grid, with: .color(hex(0xFF2FD0)), lineWidth: 1.4)
                    var hills = Path()
                    hills.move(to: CGPoint(x: 0, y: horizon))
                    for (x, h) in [(40, 30), (90, 12), (150, 44), (210, 18), (260, 36), (300, 8)] {
                        hills.addLine(to: CGPoint(x: CGFloat(x), y: horizon - CGFloat(h)))
                    }
                    hills.addLine(to: CGPoint(x: size.width, y: horizon))
                    context.fill(hills, with: .color(hex(0x22003D)))
                }
                Text("Night Drive")
                    .font(.system(size: 46, weight: .bold, design: .serif).italic())
                    .foregroundStyle(.white)
                    .shadow(color: hex(0xFF2FD0), radius: 8)
                    .offset(y: -96)
                Text("THE HALYARDS").font(.system(size: 12, weight: .bold)).tracking(4).foregroundStyle(.white)
                    .offset(y: -54)
            }
        }

        /// Low Tide: stark and minimal, black on white.
        private var lowTide: some View {
            ZStack {
                hex(0xF4F1EA)
                Circle().fill(hex(0x111111)).frame(width: 190, height: 190).offset(x: 70, y: 80)
                Rectangle().fill(hex(0x111111)).frame(width: 230, height: 2).offset(x: -20, y: -10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KESTREL").font(.system(size: 22, weight: .heavy)).tracking(2)
                    Text("low tide").font(.system(size: 18, weight: .regular, design: .serif).italic())
                }
                .foregroundStyle(hex(0x111111))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(22)
            }
        }

        /// North Light: a moonlit range of mountains and pines, layered like a photograph in haze.
        private var northLight: some View {
            ZStack {
                LinearGradient(
                    colors: [hex(0x0B1A33), hex(0x1E5A73), hex(0x9FD3C7)], startPoint: .top, endPoint: .bottom)
                Circle().fill(hex(0xFDF6E3)).frame(width: 46, height: 46).offset(x: 70, y: -86)
                    .shadow(color: .white.opacity(0.8), radius: 18)
                Canvas { context, size in
                    let layers: [(UInt32, CGFloat, [CGFloat])] = [
                        (0x355C7D, 150, [0, 60, 20, 90, 40, 70, 10]),
                        (0x24445E, 190, [30, 0, 70, 20, 60, 10, 50]),
                        (0x132A3C, 230, [10, 50, 0, 40, 20, 60, 30]),
                    ]
                    for (colour, base, peaks) in layers {
                        var ridge = Path()
                        ridge.move(to: CGPoint(x: 0, y: size.height))
                        for (i, p) in peaks.enumerated() {
                            ridge.addLine(
                                to: CGPoint(x: size.width * CGFloat(i) / CGFloat(peaks.count - 1), y: base - p))
                        }
                        ridge.addLine(to: CGPoint(x: size.width, y: size.height))
                        context.fill(ridge, with: .color(hex(colour)))
                    }
                    var random = SeededRandom(seed: 41)
                    for _ in 0..<26 {
                        let x = random.range(0, Double(size.width))
                        let h = random.range(26, 60)
                        var tree = Path()
                        tree.move(to: CGPoint(x: x, y: 300 - h))
                        tree.addLine(to: CGPoint(x: x - h * 0.22, y: 300))
                        tree.addLine(to: CGPoint(x: x + h * 0.22, y: 300))
                        context.fill(tree, with: .color(hex(0x07141E)))
                    }
                }
                VStack {
                    Text("ELSKE").font(.system(size: 20, weight: .light)).tracking(10)
                    Text("NORTH LIGHT").font(.system(size: 10, weight: .semibold)).tracking(4)
                }
                .foregroundStyle(.white)
                .offset(y: -20)
            }
        }

        /// Tessellate: a busy grid of shapes in five inks.
        private var tessellate: some View {
            Canvas { context, size in
                let palette: [UInt32] = [0xE63946, 0xF1C453, 0x2A9D8F, 0x264653, 0xF4A261, 0xF1FAEE]
                var random = SeededRandom(seed: 7)
                let cell = size.width / 6
                for row in 0..<6 {
                    for column in 0..<6 {
                        let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        let back = palette[Int(random.unit() * 6) % 6]
                        var front = palette[Int(random.unit() * 6) % 6]
                        if front == back { front = palette[(palette.firstIndex(of: back)! + 2) % 6] }
                        context.fill(Path(rect), with: .color(hex(back)))
                        var shape = Path()
                        switch Int(random.unit() * 4) {
                        case 0: shape.addEllipse(in: rect.insetBy(dx: cell * 0.12, dy: cell * 0.12))
                        case 1:
                            shape.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                            shape.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        case 2:
                            shape.move(to: CGPoint(x: rect.minX, y: rect.minY))
                            shape.addArc(
                                center: CGPoint(x: rect.minX, y: rect.minY), radius: cell, startAngle: .zero,
                                endAngle: .degrees(90), clockwise: false)
                        default: shape.addRect(rect.insetBy(dx: cell * 0.3, dy: 0))
                        }
                        context.fill(shape, with: .color(hex(front)))
                    }
                }
                let plate = CGRect(x: 20, y: 222, width: 150, height: 52)
                context.fill(Path(plate), with: .color(.black))
                context.draw(
                    Text("PLINTH").font(.system(size: 34, weight: .black)).foregroundStyle(.white),
                    at: CGPoint(x: plate.midX, y: plate.midY))
            }
        }

        /// Saffron: a portrait in profile, cut from paper, under a big serif title.
        private var saffron: some View {
            ZStack {
                hex(0xF2A93B)
                Canvas { context, size in
                    var figure = Path()
                    figure.addEllipse(in: CGRect(x: 92, y: 70, width: 120, height: 140))
                    figure.addRect(CGRect(x: 128, y: 190, width: 48, height: 50))
                    figure.addEllipse(in: CGRect(x: 40, y: 228, width: 224, height: 150))
                    context.fill(figure, with: .color(hex(0x8E1B2C)))
                    var nose = Path()
                    nose.move(to: CGPoint(x: 92, y: 128))
                    nose.addLine(to: CGPoint(x: 72, y: 150))
                    nose.addLine(to: CGPoint(x: 96, y: 156))
                    context.fill(nose, with: .color(hex(0x8E1B2C)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: 170, y: 56, width: 70, height: 70)), with: .color(hex(0xFFE08A)))
                }
                Text("Saffron")
                    .font(.system(size: 64, weight: .bold, design: .serif))
                    .foregroundStyle(hex(0xFFF4DC))
                    .offset(y: -108)
                Text("MEERA JOSHI").font(.system(size: 12, weight: .semibold)).tracking(5)
                    .foregroundStyle(hex(0xFFF4DC))
                    .offset(y: 128)
            }
        }

        /// Verdigris: a collage of torn scraps, a photo and stray type, every piece at its own angle.
        private var verdigris: some View {
            ZStack {
                hex(0x2F8F83)
                ForEach(0..<9) { k in
                    var random = SeededRandom(seed: UInt64(100 + k))
                    let colours: [UInt32] = [0xE8DCC2, 0xD1495B, 0x00798C, 0xEDAE49, 0x30638E, 0xF6F1E7]
                    Rectangle()
                        .fill(hex(colours[k % colours.count]))
                        .frame(width: random.range(70, 160), height: random.range(40, 120))
                        .rotationEffect(.degrees(random.range(-28, 28)))
                        .offset(x: random.range(-110, 110), y: random.range(-110, 110))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                }
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [hex(0xFCE38A), hex(0xF38181), hex(0x3A1C71)], center: .topLeading, startRadius: 4,
                            endRadius: 130)
                    )
                    .frame(width: 120, height: 120)
                    .overlay(Circle().stroke(.white, lineWidth: 6))
                    .offset(x: 40, y: -30)
                Text("verdigris").font(.system(size: 40, weight: .heavy, design: .serif).italic())
                    .foregroundStyle(.black)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -30, y: 90)
                Text("ANA LUNE").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(4).background(.white)
                    .rotationEffect(.degrees(12))
                    .offset(x: -80, y: -110)
                Text("side one · 2017").font(.system(size: 11, design: .serif))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(90))
                    .offset(x: 128, y: 40)
            }
        }

        /// Cathedral FM: a word set as big as the sleeve, with a sticker.
        private var cathedral: some View {
            ZStack(alignment: .topLeading) {
                hex(0x1D3FBB)
                VStack(alignment: .leading, spacing: -8) {
                    Text("CATHE").font(.system(size: 92, weight: .heavy, design: .default))
                    Text("DRAL").font(.system(size: 92, weight: .heavy, design: .default))
                }
                .foregroundStyle(.white)
                .tracking(-3)
                .padding(.leading, 12)
                .padding(.top, 20)
                Text("FM")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(hex(0x1D3FBB))
                    .padding(.horizontal, 12)
                    .background(hex(0xFFD23F))
                    .rotationEffect(.degrees(-6))
                    .offset(x: 170, y: 210)
                Text("OREN BLUE").font(.system(size: 13, weight: .bold)).tracking(4).foregroundStyle(.white)
                    .offset(x: 16, y: 262)
            }
        }

        /// Small Hours: a big sleepy face in a night sky.
        private var smallHours: some View {
            ZStack {
                LinearGradient(colors: [hex(0x0B1026), hex(0x2B2F77)], startPoint: .top, endPoint: .bottom)
                Canvas { context, size in
                    var random = SeededRandom(seed: 99)
                    for _ in 0..<60 {
                        let r = random.range(0.6, 2)
                        let point = CGRect(
                            x: random.range(0, 300), y: random.range(0, 300), width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: point), with: .color(.white.opacity(random.range(0.3, 0.9))))
                    }
                }
                Text("😴").font(.system(size: 170))
                    .offset(y: -12)
                Text("small hours").font(.system(size: 26, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: 116)
                Text("BENEDIKT").font(.system(size: 11, weight: .semibold)).tracking(5)
                    .foregroundStyle(.white.opacity(0.8))
                    .offset(y: -128)
            }
        }
    }
#endif
