import SwiftUI

/// How the spectrum area is drawn. `classic` is the measuring view; the rest are for watching.
enum Visualizer: String, CaseIterable {
    case classic, ascii, ridges, ring, lava, warp, creature

    var title: String {
        switch self {
        case .classic: "Klasik"
        case .ascii: "ASCII"
        case .ridges: "Sırtlar"
        case .ring: "Halka"
        case .lava: "Lav Lambası"
        case .warp: "Hiperuzay"
        case .creature: "Bas Canavarı"
        }
    }

    var next: Visualizer {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Output spectrum prepared for the art modes (see `AppModel.updateArt`).
struct ArtFrame {
    /// 0…1 per band, low to high.
    var levels: [Float] = []
    /// Falling peak markers.
    var peaks: [Float] = []
    /// Past `levels`, oldest first, one every three spectrum frames (10 per second).
    var history: [[Float]] = []
    /// Mean levels below 120 Hz, 250 Hz – 2.5 kHz and above 4 kHz.
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// 1 on a bass hit, decaying towards 0.
    var beat: Float = 0
    var bassAverage: Float = 0
    /// Seconds of animation, and distance flown (faster with bass and beats).
    var time = 0.0
    var travel = 0.0

    /// Spectrum and art refresh rate.
    static let frameRate = 30.0

    /// Analyzer bands from ~30 Hz to ~16 kHz (96 bands over 20 Hz – 20 kHz).
    static let bandRange = 5..<93
    /// Band power of music falls ~1.5–2 dB/octave on log-spaced bands; this levels it out.
    static let tiltDbPerOctave: Float = 2
    static let rangeDb: Float = 48
    static let ceilingFallDb: Float = 0.15
    static let minCeilingDb: Float = -60
    static let peakFall: Float = 0.012
    static let historyLength = 32

    /// Level at a fractional position 0…1 across the bands, linearly interpolated.
    static func sample(_ values: [Float], at position: Double) -> Float {
        guard values.count > 1 else { return values.first ?? 0 }
        let p = min(max(position, 0), 1) * Double(values.count - 1)
        let i = min(Int(p), values.count - 2)
        let t = Float(p - Double(i))
        return values[i] * (1 - t) + values[i + 1] * t
    }

    /// Cyan → violet → pink across 0…1.
    static func color(_ t: Double, brightness: Double = 1) -> Color {
        Color(hue: 0.52 + 0.42 * min(max(t, 0), 1), saturation: 0.75, brightness: brightness)
    }
}

/// Draws one of the art modes on a black canvas.
struct ArtVisualizerView: View {
    let mode: Visualizer
    let art: ArtFrame

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            switch mode {
            case .classic: break
            case .ascii: ascii(context, size)
            case .ridges: ridges(context, size)
            case .ring: ring(context, size)
            case .lava: lava(context, size)
            case .warp: warp(context, size)
            case .creature: creature(context, size)
            }
        }
    }

    // MARK: ASCII — bars made of characters, denser towards the top of the area, like cava.

    private static let ramp = Array(" .:-=+*#%@")
    private static let fontSize: CGFloat = 9
    private static let lineHeight: CGFloat = 9

    private func ascii(_ context: GraphicsContext, _ size: CGSize) {
        let charWidth = Self.fontSize * 0.602
        let cols = max(Int((size.width - 8) / charWidth), 1)
        let rows = max(Int((size.height - 4) / Self.lineHeight), 1)
        let heights = (0..<cols).map { Double(ArtFrame.sample(art.levels, at: Double($0) / Double(max(cols - 1, 1)))) * Double(rows) }
        let peaks = (0..<cols).map { Double(ArtFrame.sample(art.peaks, at: Double($0) / Double(max(cols - 1, 1)))) * Double(rows) }
        for row in 0..<rows {
            let line = String((0..<cols).map { col -> Character in
                let fill = min(max(heights[col] - Double(row), 0), 1)
                if fill <= 0.05 {
                    return Int(peaks[col]) == row && peaks[col] > 0.5 ? "_" : " "
                }
                let density = fill * (0.35 + 0.65 * Double(row + 1) / Double(rows))
                return Self.ramp[max(1, min(Self.ramp.count - 1, Int(density * Double(Self.ramp.count))))]
            })
            let t = Double(row) / Double(max(rows - 1, 1))
            let text = Text(line).font(.system(size: Self.fontSize, design: .monospaced))
                .foregroundStyle(ArtFrame.color(t, brightness: 0.7 + 0.3 * t))
            let y = size.height - 2 - CGFloat(row) * Self.lineHeight
            context.draw(text, at: CGPoint(x: 4, y: y), anchor: .bottomLeading)
        }
    }

    // MARK: Sırtlar — stacked lines of the recent past, newest in front (Unknown Pleasures).

    private static let ridgeLines = 26
    private static let ridgePoints = 72

    private func ridges(_ context: GraphicsContext, _ size: CGSize) {
        let lines = Array(art.history.suffix(Self.ridgeLines))
        guard !lines.isEmpty else { return }
        let margin = size.width * 0.12
        let amp = size.height * 0.42
        let top = amp * 0.55
        let spacing = (size.height - 4 - top) / CGFloat(max(Self.ridgeLines - 1, 1))
        let firstSlot = Self.ridgeLines - lines.count
        for (i, levels) in lines.enumerated() {
            let base = top + CGFloat(firstSlot + i) * spacing
            var path = Path()
            for p in 0...Self.ridgePoints {
                let u = Double(p) / Double(Self.ridgePoints)
                // Taller in the middle, flat at the ends, like the original plot.
                let envelope = 0.15 + 0.85 * pow(sin(.pi * u), 1.5)
                let v = CGFloat(Double(ArtFrame.sample(levels, at: u)) * envelope)
                let point = CGPoint(x: margin + u * (size.width - 2 * margin), y: base - v * amp)
                if p == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var shape = path
            shape.addLine(to: CGPoint(x: size.width - margin, y: base + 1))
            shape.addLine(to: CGPoint(x: margin, y: base + 1))
            shape.closeSubpath()
            context.fill(shape, with: .color(.black))
            let age = Double(i + 1) / Double(lines.count)
            context.stroke(path, with: .color(.white.opacity(0.35 + 0.65 * age)), lineWidth: 1)
        }
    }

    // MARK: Halka — bars around a circle, mirrored, with a glow and a bass-driven core.

    private func ring(_ context: GraphicsContext, _ size: CGSize) {
        guard !art.levels.isEmpty else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let inner = radius * (0.34 + 0.12 * CGFloat(art.bass))
        let length = radius - inner - 3
        let count = 64
        var bars: [(Path, Color)] = []
        for j in 0..<count {
            let u = Double(j) / Double(count - 1)
            let v = CGFloat(ArtFrame.sample(art.levels, at: u))
            for side in [-1.0, 1.0] {
                let angle = -Double.pi / 2 + side * u * Double.pi
                let dir = CGPoint(x: cos(angle), y: sin(angle))
                let a = CGPoint(x: center.x + dir.x * inner, y: center.y + dir.y * inner)
                let b = CGPoint(x: center.x + dir.x * (inner + 2 + v * length), y: center.y + dir.y * (inner + 2 + v * length))
                bars.append((Path { $0.move(to: a); $0.addLine(to: b) }, ArtFrame.color(u)))
            }
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            for (path, color) in bars { glow.stroke(path, with: .color(color), lineWidth: 3.5) }
        }
        for (path, color) in bars { context.stroke(path, with: .color(color), lineWidth: 1.6) }
        let core = Path(ellipseIn: CGRect(x: center.x - inner * 0.8, y: center.y - inner * 0.8,
                                          width: inner * 1.6, height: inner * 1.6))
        context.fill(core, with: .radialGradient(
            Gradient(colors: [ArtFrame.color(0.9).opacity(0.25 + 0.6 * Double(art.bass)), .clear]),
            center: center, startRadius: 0, endRadius: inner * 0.8))
    }

    // MARK: Lav Lambası — gooey blobs (blur + alpha threshold), each one riding a band.

    /// Fixed pseudo-random 0…1 per index.
    private static func hash(_ i: Int, _ salt: Double = 0) -> Double {
        let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    private func lava(_ context: GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [Color(hue: 0.8, saturation: 0.8, brightness: 0.28), .black]),
            center: CGPoint(x: size.width / 2, y: size.height), startRadius: 0, endRadius: size.width * 0.7))
        let t = art.time * 0.3 + art.travel * 0.12
        let groups: [(range: Range<Int>, color: Color)] = [
            (0..<5, Color(hue: 0.06, saturation: 0.9, brightness: 1)),
            (5..<10, Color(hue: 0.9, saturation: 0.75, brightness: 1)),
        ]
        for group in groups {
            var layer = context
            layer.addFilter(.alphaThreshold(min: 0.5, color: group.color))
            layer.addFilter(.blur(radius: 9))
            layer.drawLayer { blobs in
                for i in group.range {
                    let u = (Double(i) + 0.5) / 10
                    let level = Double(ArtFrame.sample(art.levels, at: u))
                    let x = size.width * (0.5 + 0.42 * sin(t * (0.5 + Self.hash(i)) + 6 * Self.hash(i, 1)))
                    // Low bands sink, high bands float; loud blobs rise.
                    let y = size.height * (0.62 - 0.25 * u - 0.2 * level + 0.25 * sin(t * (0.4 + Self.hash(i, 2)) + 6 * Self.hash(i, 3)))
                    let r = size.height * (0.06 + 0.14 * level) * (1 + 0.25 * Double(art.beat))
                    blobs.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white))
                }
                // A pool at the bottom that swells with the bass.
                let pool = size.height * (0.07 + 0.1 * Double(art.bass))
                blobs.fill(Path(CGRect(x: 0, y: size.height - pool, width: size.width, height: pool)), with: .color(.white))
            }
        }
    }

    // MARK: Hiperuzay — a starfield flown through faster on bass, a shockwave on each beat.

    private func warp(_ context: GraphicsContext, _ size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = hypot(size.width, size.height) / 2
        let speed = 0.25 + 2.5 * Double(art.bass) + 1.5 * Double(art.beat)
        let hue = 0.55 + 0.4 * Double(art.treble)
        for i in 0..<160 {
            let angle = Self.hash(i) * 2 * .pi
            let s = (Self.hash(i, 1) + art.travel * 0.3).truncatingRemainder(dividingBy: 1)
            let trail = min(0.02 + 0.05 * speed, s)
            let r1 = reach * pow(s, 2.4)
            let r0 = reach * pow(s - trail, 2.4)
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let path = Path {
                $0.move(to: CGPoint(x: center.x + dir.x * r0, y: center.y + dir.y * r0))
                $0.addLine(to: CGPoint(x: center.x + dir.x * r1, y: center.y + dir.y * r1))
            }
            let tint = Color(hue: (hue + 0.15 * Self.hash(i, 2)).truncatingRemainder(dividingBy: 1),
                             saturation: 0.35 + 0.4 * Self.hash(i, 3), brightness: 1)
            context.stroke(path, with: .color(tint.opacity(min(1, 0.2 + s * 1.5))), lineWidth: 0.5 + 2.2 * s)
        }
        // Beat shockwave and the glowing core.
        if art.beat > 0.05 {
            let r = reach * (1.05 - Double(art.beat))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Color(hue: hue, saturation: 0.6, brightness: 1).opacity(Double(art.beat) * 0.8)),
                           lineWidth: 1 + 4 * CGFloat(art.beat))
        }
        let core = 6 + 16 * CGFloat(art.bass) + 10 * CGFloat(art.beat)
        context.fill(Path(ellipseIn: CGRect(x: center.x - core * 2, y: center.y - core * 2, width: core * 4, height: core * 4)),
                     with: .radialGradient(Gradient(colors: [.white, Color(hue: hue, saturation: 0.8, brightness: 1).opacity(0.5), .clear]),
                                           center: center, startRadius: 0, endRadius: core * 2))
    }

    // MARK: Bas Canavarı — a furry blob that bounces on the bass, sings the mids and
    // bristles with the treble. It also blinks.

    private func creature(_ context: GraphicsContext, _ size: CGSize) {
        let t = art.time
        let beat = CGFloat(art.beat), bass = CGFloat(art.bass), mid = CGFloat(art.mid), treble = CGFloat(art.treble)
        // Disco floor and confetti on beats.
        for i in 0..<14 {
            let x = size.width * (CGFloat(i) + 0.5) / 14
            let lit = Self.hash(i, (t * 2).rounded(.down)) > 0.6
            context.fill(Path(ellipseIn: CGRect(x: x - 10, y: size.height - 9, width: 20, height: 6)),
                         with: .color(Color(hue: Self.hash(i, 4), saturation: 0.8, brightness: lit ? 0.9 : 0.25)))
        }
        if beat > 0.1 {
            for i in 0..<24 {
                let x = size.width * Self.hash(i, art.travel.rounded(.down))
                let y = size.height * (0.05 + 0.6 * Self.hash(i, 9)) + (1 - beat) * 30
                context.fill(Path(CGRect(x: x, y: y, width: 3, height: 3)),
                             with: .color(Color(hue: Self.hash(i, 7), saturation: 0.9, brightness: 1).opacity(Double(beat))))
            }
        }

        let r = size.height * 0.27 * (1 + 0.12 * bass)
        let center = CGPoint(x: size.width / 2 + 10 * CGFloat(sin(t * 1.3)), y: size.height - 12 - r * (1 - 0.15 * beat) - 18 * beat)
        let sx = 1 + 0.18 * beat, sy = 1 - 0.14 * beat
        let bodyHue = (0.28 + 0.06 * sin(t * 0.2)).truncatingRemainder(dividingBy: 1)

        // Antennae with bobbing balls.
        for side in [-1.0, 1.0] {
            let base = CGPoint(x: center.x + CGFloat(side) * r * 0.35, y: center.y - r * sy * 0.85)
            let tip = CGPoint(x: base.x + CGFloat(side) * (14 + 8 * CGFloat(sin(t * 3 + side))),
                              y: base.y - 22 - 16 * treble)
            context.stroke(Path { $0.move(to: base); $0.addQuadCurve(to: tip, control: CGPoint(x: base.x, y: tip.y)) },
                           with: .color(Color(hue: bodyHue, saturation: 0.7, brightness: 0.7)), lineWidth: 2)
            let ball = 3 + 4 * treble
            context.fill(Path(ellipseIn: CGRect(x: tip.x - ball, y: tip.y - ball, width: 2 * ball, height: 2 * ball)),
                         with: .color(Color(hue: 0.92, saturation: 0.7, brightness: 1)))
        }

        // Furry body: the spectrum bristles around the top half.
        var body = Path()
        let points = 90
        for p in 0...points {
            let a = Double(p) / Double(points) * 2 * .pi
            let upper = max(0, -sin(a))
            let u = (cos(a) + 1) / 2
            let fur = CGFloat(ArtFrame.sample(art.levels, at: u)) * CGFloat(upper) * (p % 2 == 0 ? 0.35 : 0.08)
            let rr = r * (1 + fur)
            let point = CGPoint(x: center.x + CGFloat(cos(a)) * rr * sx, y: center.y + CGFloat(sin(a)) * rr * sy)
            if p == 0 { body.move(to: point) } else { body.addLine(to: point) }
        }
        body.closeSubpath()
        context.fill(body, with: .linearGradient(
            Gradient(colors: [Color(hue: bodyHue, saturation: 0.75, brightness: 0.95), Color(hue: bodyHue + 0.08, saturation: 0.85, brightness: 0.55)]),
            startPoint: CGPoint(x: center.x, y: center.y - r), endPoint: CGPoint(x: center.x, y: center.y + r)))

        // Googly eyes that look around and blink every few seconds.
        let blink = (t.truncatingRemainder(dividingBy: 3.7)) < 0.15
        let look = CGPoint(x: CGFloat(sin(t * 0.9)) * 0.35, y: CGFloat(cos(t * 1.3)) * 0.25 - 0.2 * beat)
        for side in [-1.0, 1.0] {
            let er = r * (0.27 + 0.08 * beat) * (side < 0 ? 1 : 0.85)
            let ec = CGPoint(x: center.x + CGFloat(side) * r * 0.38 * sx, y: center.y - r * 0.25 * sy)
            let eye = CGRect(x: ec.x - er, y: ec.y - er * (blink ? 0.1 : 1), width: 2 * er, height: 2 * er * (blink ? 0.1 : 1))
            context.fill(Path(ellipseIn: eye), with: .color(.white))
            guard !blink else { continue }
            let pr = er * 0.45
            let pc = CGPoint(x: ec.x + look.x * er, y: ec.y + look.y * er)
            context.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: 2 * pr, height: 2 * pr)), with: .color(.black))
            context.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.2, y: pc.y - pr * 0.6, width: pr * 0.5, height: pr * 0.5)), with: .color(.white))
        }

        // Singing mouth: opens with the mids.
        let mw = r * (0.45 + 0.2 * mid), mh = 3 + r * 0.55 * mid
        let mouth = CGRect(x: center.x - mw / 2, y: center.y + r * 0.3 * sy - mh / 2, width: mw, height: mh)
        context.fill(Path(ellipseIn: mouth), with: .color(Color(hue: 0.98, saturation: 0.8, brightness: 0.3)))
        if mh > 8 {
            context.fill(Path(ellipseIn: CGRect(x: mouth.midX - mw * 0.22, y: mouth.maxY - mh * 0.45, width: mw * 0.44, height: mh * 0.4)),
                         with: .color(Color(hue: 0.97, saturation: 0.6, brightness: 0.9)))
        }
    }
}
