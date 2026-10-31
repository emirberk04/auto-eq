import EQCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @State private var showDetails = false
    @State private var showPastDiscoveries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.enabled { spectrum }
            if let design = model.design {
                ResponseView(design: design, preampDb: model.status.settings.preampDb).frame(height: 80)
                eqControls(design)
            }
            discoverSection
            warnings
            DisclosureGroup("Durum", isExpanded: $showDetails) { details }
                .font(.callout)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Sections

    /// The live spectrum, or one of the art modes; the button (or a click) switches between them.
    private var spectrum: some View {
        Group {
            if model.visualizer == .classic {
                SpectrumView(model: model).frame(height: 120)
            } else {
                ArtVisualizerView(mode: model.visualizer, art: model.art)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setVisualizer(model.visualizer.next) }
        .overlay(alignment: .topLeading) {
            Menu {
                ForEach(Visualizer.allCases, id: \.self) { mode in
                    Button(mode.title) { model.setVisualizer(mode) }
                }
            } label: {
                Label(model.visualizer.title, systemImage: "sparkles").font(.system(size: 10))
            } primaryAction: {
                model.setVisualizer(model.visualizer.next)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.35)))
            .padding(4)
        }
        .help("Görünümü değiştir: tıkla (sırayla) veya ok ile seç")
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("S12 Adaptive EQ").font(.headline)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Etkin", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Kapalı: uygulama sesi hiç işlemez (orijinal yol).")
        }
    }

    private func eqControls(_ design: EQDesign) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("EQ", isOn: Binding(get: { design.eqEnabled }, set: { v in model.update { $0.eqEnabled = v } }))
                    .help("S12 Ultra → Harman düzeltmesi + bas/tiz. Kapalı: bypass (50 ms geçiş).")
                    .keyboardShortcut("e", modifiers: [])
                Spacer()
                Toggle("A/B seviye eşitle", isOn: Binding(get: { design.levelMatch }, set: { v in model.update { $0.levelMatch = v } }))
                    .help("Açık: bypass, EQ ile aynı algısal seviyeye kısılır. Kapalı: bypass orijinalle bit düzeyinde aynı.")
            }
            .toggleStyle(.checkbox)

            Picker("Ton", selection: Binding(get: { design.tone }, set: { v in model.update { $0.tone = v } })) {
                Text("Doğal").tag(EQDesign.Tone.natural)
                Text("Harman").tag(EQDesign.Tone.harman)
            }
            .pickerStyle(.segmented)
            .help("Doğal: S12 Ultra'nın kendi sesi. Harman: ölçüme göre Harman In-Ear 2019 hedefine düzeltme.")
            if design.tone == .harman {
                LabeledSlider(title: "Kuvvet", value: design.strength * 100, range: 0...100, step: 5,
                              format: { "\(Int($0.rounded())) %" }, defaultValue: design.profile.defaultStrength * 100) { v in
                    model.update { $0.strength = v / 100 }
                }
            }
            LabeledSlider(title: "Bas", value: design.bassDb, range: EQDesign.bassRange, step: 0.5,
                          format: Self.db, defaultValue: 0) { v in model.update { $0.bassDb = v } }
            LabeledSlider(title: "Tiz", value: design.trebleDb, range: EQDesign.trebleRange, step: 0.5,
                          format: Self.db, defaultValue: 0) { v in model.update { $0.trebleDb = v } }
            loudnessControls(design)
            adaptationControls(design)
        }
    }

    private func loudnessControls(_ design: EQDesign) -> some View {
        let gains = design.loudnessGains
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Kısık ses telafisi", isOn: Binding(get: { design.loudnessCompensation },
                                                           set: { v in model.update { $0.loudnessCompensation = v } }))
                    .toggleStyle(.checkbox)
                    .help("ISO 226: ses kısıldıkça kulak bası ve tizi daha az duyar; bu, ses seviyesine göre geri ekler.")
                Spacer()
                if design.loudnessCompensation, model.volumeDb != nil {
                    Text(String(format: "bas +%.1f · tiz +%.1f dB", gains.bass, gains.treble))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if design.loudnessCompensation {
                if let volume = model.volumeDb, let reference = model.referenceVolumeDb {
                    HStack {
                        Text(String(format: "ses %.0f dB · referans %.0f dB", volume, reference))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Şu anki ses = referans") { model.setReferenceToCurrentVolume() }
                            .controlSize(.small)
                            .help("En yüksek, rahat dinleme seviyende bas. Bu seviyede telafi sıfır, altında artar.")
                    }
                } else {
                    Text("Çıkış cihazının ses seviyesi okunamıyor; telafi kapalı.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func adaptationControls(_ design: EQDesign) -> some View {
        let a = model.adaptation
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Şarkıya uyum", isOn: Binding(get: { design.adaptEnabled }, set: { v in model.update { $0.adaptEnabled = v } }))
                    .toggleStyle(.checkbox)
                    .help("L3: şarkının ton dengesine göre yavaş, küçük düzeltme (bant başına ±2 dB). Kapalı/açık seviye eşit.")
                Spacer()
                Text(adaptationPhaseText).font(.caption).foregroundStyle(.secondary)
            }
            LabeledSlider(title: "Uyum", value: design.adaptStrength * 100, range: 0...100, step: 5,
                          format: { "\(Int($0.rounded())) %" }, defaultValue: EQDesign.defaultAdaptStrength * 100) { v in
                model.update { $0.adaptStrength = v / 100 }
            }
            .disabled(!design.adaptEnabled)
            Text(a.usesLibraryTarget ? "Hedef: kütüphanenin ortalama dengesi (\(a.libraryTracks) parça)"
                 : "Hedef: genel eğri (kütüphane \(a.libraryTracks)/\(AdaptiveFit.minLibraryTracks) parça)")
                .font(.caption).foregroundStyle(.secondary)
            if let title = a.title {
                Text(a.artist.map { "\(title) — \($0)" } ?? title)
                    .font(.caption).lineLimit(1).truncationMode(.tail)
            }
            if a.features.seconds > 0 {
                Text(featuresText(a.features))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private var adaptationPhaseText: String {
        let a = model.adaptation
        guard model.status.state == .running else { return "" }
        if !a.playing { return "bekliyor (ses yok)" }
        switch a.phase {
        case .learning: return "dinliyor \(Int(min(a.ownSeconds, AdaptationController.freezeSeconds)))/\(Int(AdaptationController.freezeSeconds)) sn"
        case .cached: return "önbellekten"
        case .adapting: return a.fromCache ? "uyarlanıyor (önbellek + canlı)" : "uyarlanıyor"
        }
    }

    private func featuresText(_ f: TrackFeatures) -> String {
        var parts = [String(format: "eğim %.1f dB/okt", f.tiltDbPerOctave)]
        if f.integratedLufs.isFinite { parts.append(String(format: "%.1f LUFS", f.integratedLufs)) }
        if f.plrDb > 0 { parts.append(String(format: "PLR %.1f", f.plrDb)) }
        parts.append(String(format: "crest %.1f", f.crestDb))
        return parts.joined(separator: " · ")
    }

    // MARK: Keşfet

    /// Random little-known tracks with good sound, unrelated to what is usually played.
    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    model.discovering ? model.cancelDiscovery() : model.discover()
                } label: {
                    Label(model.discovering ? "Durdur" : "Keşfet", systemImage: model.discovering ? "stop.fill" : "dice")
                }
                if model.discovering { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Sözlü", isOn: Binding(get: { model.discoverVocalsOnly }, set: { model.setDiscoverVocalsOnly($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                    .help("Sadece şarkı söylenen ya da rap olan parçalar")
                Toggle("Bulunca aç", isOn: Binding(get: { model.discoverAutoOpen }, set: { model.setDiscoverAutoOpen($0) }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            if let status = model.discoveryStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let latest = model.discoveries.first {
                discoveryCard(latest)
            }
            if model.discoveries.count > 1 {
                DisclosureGroup("Önceki keşifler (\(model.discoveries.count - 1))", isExpanded: $showPastDiscoveries) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.discoveries.dropFirst()) { d in
                            Button { model.open(d) } label: {
                                HStack {
                                    Text("\(d.title) — \(d.artist)").lineLimit(1)
                                    Spacer()
                                    Text(d.genre).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.caption)
                }
                .font(.caption)
            }
        }
    }

    private func discoveryCard(_ d: Discovery) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(d.artist).font(.caption).lineLimit(1)
                HStack(spacing: 6) {
                    Text(d.genre).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.purple.opacity(0.25)))
                    Text(verbatim: "ses \(Int(d.score.rounded()))/100 · PLR \(Int(d.plrDb.rounded())) dB"
                         + (d.vocals.map { " · vokal %\(Int(($0 * 100).rounded()))" } ?? ""))
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                if !d.issues.isEmpty {
                    Text(d.issues.joined(separator: ", ")).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Music'te aç") { model.open(d) }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder private var warnings: some View {
        let s = model.status
        if model.profileError != nil || s.permissionSuspect || s.limiterActive || !s.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let e = model.profileError { warning("Profil yüklenemedi: \(e)") }
                if s.permissionSuspect {
                    warning("Ses gelmiyor: ses kaydı izni verilmemiş olabilir (Sistem Sesi Kaydı).")
                    Button("Gizlilik ayarlarını aç…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .controlSize(.small)
                }
                if s.limiterActive { warning("Limiter devrede (kırpılma önleniyor).") }
                ForEach(s.warnings, id: \.self) { warning($0) }
            }
        }
    }

    private var details: some View {
        let s = model.status
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            row("Çıkış", s.outputDeviceName.isEmpty ? "—" : s.outputDeviceName)
            row("Örnekleme", s.deviceSampleRate > 0 ? String(format: "%.1f kHz · tampon %d", s.deviceSampleRate / 1000, s.bufferFrames) : "—")
            row("Gecikme", s.measuredLatencyMs > 0 ? String(format: "%.1f ms", s.measuredLatencyMs) : "—")
            row("Preamp", String(format: "%.1f dB", s.settings.preampDb))
            row("Bypass seviyesi", String(format: "%.1f dB", s.settings.dryGainDb))
            row("Tampon sağlığı", "aşırı yük \(s.overloads) · uyumsuz \(s.frameMismatches)")
            row("Limiter", s.limitedFramesTotal == 0 ? "hiç devreye girmedi"
                : String(format: "toplam %.1f sn", Double(s.limitedFramesTotal) / max(s.deviceSampleRate, 1)))
            row("Yeniden kurulum", "\(max(0, s.rebuilds - 1))")
            row("Uyum (L3)", model.design.map { d in d.adaptiveGains.map { String(format: "%+.1f", $0) }.joined(separator: " ") } ?? "—")
            row("Parça değişimi", "\(model.adaptation.trackChanges)" + (model.adaptation.lastChange.map { " · son: \($0)" } ?? ""))
            row("Önbellek", "\(model.adaptation.cachedTracks) parça")
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Yakalama", selection: Binding(get: { model.captureMode }, set: { model.setCaptureMode($0) })) {
                Text("Music.app").tag(CaptureMode.music)
                Text("Tüm sistem").tag(CaptureMode.system)
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Girişte başlat", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }
            }
            if let e = model.loginItemError { warning(e) }
        }
        .font(.callout)
    }

    // MARK: Helpers

    private var stateText: String {
        switch model.status.state {
        case .stopped: "Kapalı — orijinal ses"
        case .waitingForSource: "Music.app bekleniyor"
        case .running: model.design?.eqEnabled == true ? "EQ açık · \(model.status.outputDeviceName)" : "Bypass · \(model.status.outputDeviceName)"
        case .failed(let message): "Hata: \(message)"
        }
    }

    private static func db(_ v: Double) -> String {
        v == 0 ? "0 dB" : String(format: "%+.1f dB", v)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// Slider with title, value readout and double-click-to-reset on the title.
private struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let defaultValue: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 52, alignment: .leading)
                .onTapGesture(count: 2) { onChange(defaultValue) }
                .help("Çift tık: varsayılan (\(format(defaultValue)))")
            Slider(value: Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }), in: range)
            Text(format(value))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout)
    }
}

// MARK: - Charts

private enum LogAxis {
    static let min = 20.0, max = 20_000.0
    static func x(_ f: Double, width: CGFloat) -> CGFloat {
        CGFloat(log10(f / min) / log10(max / min)) * width
    }
    static let gridFrequencies: [(Double, String)] = [(100, "100"), (1000, "1k"), (10_000, "10k")]

    static func grid(_ context: GraphicsContext, _ size: CGSize) {
        for (f, label) in gridFrequencies {
            let x = Self.x(f, width: size.width)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 2, y: size.height - 2), anchor: .bottomLeading)
        }
    }
}

/// Live spectrum of the tap input (grey) and the final output (accent), dBFS.
private struct SpectrumView: View {
    let model: AppModel
    private let floorDb: Float = -96

    var body: some View {
        Canvas { context, size in
            LogAxis.grid(context, size)
            for db in stride(from: -24, through: -84, by: -24) {
                let y = y(Float(db), size.height)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            let centers = model.analyzer.centers
            draw(model.inputSpectrum, centers, context, size, .secondary.opacity(0.7))
            draw(model.outputSpectrum, centers, context, size, .accentColor)
            context.draw(Text("giriş").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: size.width - 34, y: 2), anchor: .topTrailing)
            context.draw(Text("çıkış").font(.system(size: 9)).foregroundStyle(Color.accentColor),
                         at: CGPoint(x: size.width - 4, y: 2), anchor: .topTrailing)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func y(_ db: Float, _ height: CGFloat) -> CGFloat {
        CGFloat((0 - max(db, floorDb)) / (0 - floorDb)) * height
    }

    private func draw(_ levels: [Float], _ centers: [Double], _ context: GraphicsContext, _ size: CGSize, _ color: Color) {
        guard levels.count == centers.count, !levels.isEmpty else { return }
        var path = Path()
        for (i, (level, f)) in zip(levels, centers).enumerated() {
            let p = CGPoint(x: LogAxis.x(f, width: size.width), y: y(level, size.height))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2)
    }
}

/// Total EQ curve (L0 × strength + bass/treble + L3), the same with preamp, and L3 alone, ±12 dB.
private struct ResponseView: View {
    let design: EQDesign
    let preampDb: Double
    private let rangeDb = 12.0

    var body: some View {
        let bands = design.bands(sampleRate: 96_000)
        let l3 = zip(AdaptiveCorrection.filters, design.adaptiveGains).map {
            BandParameters(type: $0.type, frequency: $0.frequency, q: $0.q, gainDb: $1)
        }
        Canvas { context, size in
            LogAxis.grid(context, size)
            let zero = y(0, size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: zero)); $0.addLine(to: CGPoint(x: size.width, y: zero)) },
                           with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            context.stroke(curve(bands, offset: 0, size), with: .color(.orange), lineWidth: 1.5)
            context.stroke(curve(bands, offset: preampDb, size), with: .color(.orange.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.stroke(curve(l3, offset: 0, size), with: .color(.green), lineWidth: 1.2)
            context.draw(Text("EQ eğrisi ±12 dB · kesikli: preamp dahil").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 4, y: 2), anchor: .topLeading)
            context.draw(Text("yeşil: uyum").font(.system(size: 9)).foregroundStyle(.green),
                         at: CGPoint(x: size.width - 4, y: 2), anchor: .topTrailing)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(design.eqEnabled ? 1 : 0.4)
    }

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        CGFloat((rangeDb - min(max(db, -rangeDb), rangeDb)) / (2 * rangeDb)) * height
    }

    private func curve(_ bands: [BandParameters], offset: Double, _ size: CGSize) -> Path {
        var path = Path()
        let steps = 160
        for i in 0...steps {
            let f = LogAxis.min * pow(LogAxis.max / LogAxis.min, Double(i) / Double(steps))
            let db = EQDesign.responseDb(bands, at: f, sampleRate: 96_000) + offset
            let p = CGPoint(x: LogAxis.x(f, width: size.width), y: y(db, size.height))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
