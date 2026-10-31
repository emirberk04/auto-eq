import AppKit
import EQCore
import Observation
import ServiceManagement
import os

/// UI state and persistence. Owns the engine; every user change goes through here so it is
/// applied to the audio path and saved in one place.
@MainActor
@Observable
final class AppModel {
    private enum Key {
        static let enabled = "enabled"
        static let captureMode = "captureMode"
        static let eqEnabled = "eqEnabled"
        static let levelMatch = "levelMatch"
        static let strength = "strength"
        static let bass = "bassDb"
        static let treble = "trebleDb"
        static let adaptEnabled = "adaptEnabled"
        static let adaptStrength = "adaptStrength"
        static let tone = "tone"
        static let loudnessCompensation = "loudnessCompensation"
        static let referenceVolumeDb = "referenceVolumeDb"
        static let visualizer = "visualizer"
        static let discoveries = "discoveries"
        static let discoverAutoOpen = "discoverAutoOpen"
        static let discoveredIds = "discoveredIds"
        static let discoverVocalsOnly = "discoverVocalsOnly"
    }

    /// L2: assume the usual listening volume is this far below the reference until the
    /// listener sets the reference themselves.
    static let defaultReferenceHeadroomDb = 10.0

    @ObservationIgnored let engine: TapEngine
    @ObservationIgnored private let log = Logger(subsystem: "com.emiralan.s12-adaptive-eq", category: "AppModel")
    @ObservationIgnored private let defaults = UserDefaults.standard

    private(set) var enabled: Bool
    private(set) var captureMode: CaptureMode
    private(set) var design: EQDesign?
    private(set) var profileError: String?
    private(set) var status = TapEngine.Status()
    private(set) var launchAtLogin = false
    private(set) var loginItemError: String?
    /// L3 / analysis state, refreshed every 0.5 s.
    private(set) var adaptation = AdaptationSnapshot()
    @ObservationIgnored private var adaptationService: AdaptationService?
    @ObservationIgnored private var nowPlaying: NowPlaying?
    @ObservationIgnored private var volumeMonitor: VolumeMonitor?
    /// Output volume (dB) and L2 reference; nil when unreadable / not set yet.
    private(set) var volumeDb: Double?
    private(set) var referenceVolumeDb: Double?

    /// Spectrum levels (dBFS per band) for the tap input and the final output; empty when idle.
    private(set) var inputSpectrum: [Float] = []
    private(set) var outputSpectrum: [Float] = []
    @ObservationIgnored let analyzer = SpectrumAnalyzer()
    @ObservationIgnored private var scratch = [Float](repeating: 0, count: 4096)
    /// Keşfet: the latest finds (newest first, persisted), search state, auto-open in Music.
    private(set) var discoveries: [Discovery] = []
    private(set) var discoveryStatus: String?
    private(set) var discovering = false
    private(set) var discoverAutoOpen: Bool
    /// Only tracks with singing or rapping.
    private(set) var discoverVocalsOnly: Bool
    @ObservationIgnored private let discoveryEngine = DiscoveryEngine()
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// trackIds already suggested, so nothing repeats.
    @ObservationIgnored private var discoveredIds: Set<Int> = []
    static let discoveryHistoryLength = 30

    /// How the spectrum area is drawn, and the normalised output levels the art modes use.
    private(set) var visualizer: Visualizer
    private(set) var art = ArtFrame()
    @ObservationIgnored private var artCeilingDb: Float = -60
    @ObservationIgnored private var artFrames = 0
    @ObservationIgnored private var spectrumTimer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var ticks = 0

    init(startEngine: Bool = true) {
        defaults.register(defaults: [
            Key.enabled: true, Key.captureMode: CaptureMode.music.rawValue,
            Key.eqEnabled: true, Key.levelMatch: true,
            Key.adaptEnabled: true, Key.adaptStrength: EQDesign.defaultAdaptStrength,
            Key.tone: EQDesign.Tone.natural.rawValue, Key.loudnessCompensation: true,
            Key.discoverAutoOpen: true, Key.discoverVocalsOnly: true,
        ])
        discoverAutoOpen = defaults.bool(forKey: Key.discoverAutoOpen)
        discoverVocalsOnly = defaults.bool(forKey: Key.discoverVocalsOnly)
        let saved = defaults.data(forKey: Key.discoveries).flatMap { try? JSONDecoder().decode([Discovery].self, from: $0) } ?? []
        discoveries = saved
        discoveredIds = Set((defaults.array(forKey: Key.discoveredIds) as? [Int]) ?? saved.map(\.id))
        referenceVolumeDb = defaults.object(forKey: Key.referenceVolumeDb) as? Double
        enabled = defaults.bool(forKey: Key.enabled)
        visualizer = Visualizer(rawValue: defaults.string(forKey: Key.visualizer) ?? "") ?? .classic
        let mode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .music
        captureMode = mode
        engine = TapEngine(mode: mode)
        loadDesign()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        guard startEngine else { return }
        startAdaptation()
        let monitor = VolumeMonitor()
        monitor.onChange = { [weak self] in self?.volumeChanged() }
        volumeMonitor = monitor
        volumeChanged()
        if enabled { engine.start() }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        // Common modes: keeps ticking while a menu or the popover is tracking events.
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        tick()
    }

    private func tick() {
        status = engine.refreshStatus()
        if status.state == .running { adaptationService?.setSampleRate(status.deviceSampleRate) }
        ticks += 1
        if ticks % 10 == 0 {
            engine.logHealth()
            adaptationService?.logState()
        }
    }

    // MARK: - Adaptation (L3)

    private func startAdaptation() {
        let service = AdaptationService(kernel: engine.kernel)
        service.onUpdate = { [weak self] snapshot in self?.received(snapshot) }
        adaptationService = service
        let nowPlaying = NowPlaying()
        nowPlaying.onTrack = { [weak self] track in
            guard let self else { return }
            self.adaptationService?.noteTrack(track, authoritative: self.captureMode == .music)
        }
        self.nowPlaying = nowPlaying
    }

    private func received(_ snapshot: AdaptationSnapshot) {
        adaptation = snapshot
        guard var design, design.adaptive != snapshot.correction else { return }
        design.adaptive = snapshot.correction
        self.design = design
        engine.apply(design)
    }

    /// Saves the current track's analysis before quitting.
    func prepareForQuit() { adaptationService?.flush() }

    // MARK: - Actions

    func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Key.enabled)
        if on { engine.start() } else { engine.stop() }
    }

    func setCaptureMode(_ mode: CaptureMode) {
        captureMode = mode
        defaults.set(mode.rawValue, forKey: Key.captureMode)
        engine.setMode(mode)
        // Music.app's track notifications only describe what we hear when we tap Music.app alone.
        adaptationService?.setMetadataAuthoritative(mode == .music && nowPlaying?.seenAny == true)
    }

    // MARK: - Keşfet

    func discover() {
        guard !discovering else { return }
        discovering = true
        discoveryStatus = "Tür seçiliyor…"
        let seen = discoveredIds, vocals = discoverVocalsOnly
        discoveryTask = Task {
            do {
                let found = try await discoveryEngine.discover(excluding: seen, requireVocals: vocals) { progress in
                    Task { @MainActor in
                        guard self.discovering else { return }
                        self.discoveryStatus = progress.checked == 0
                            ? "Tür: \(progress.genre) · aday aranıyor…"
                            : "Tür: \(progress.genre) · \(progress.checked). aday ölçülüyor…"
                    }
                }
                discoveries.insert(found, at: 0)
                discoveries = Array(discoveries.prefix(Self.discoveryHistoryLength))
                discoveredIds.insert(found.id)
                defaults.set(try? JSONEncoder().encode(discoveries), forKey: Key.discoveries)
                defaults.set(Array(discoveredIds), forKey: Key.discoveredIds)
                discoveryStatus = nil
                if discoverAutoOpen { open(found) }
            } catch is CancellationError {
                discoveryStatus = nil
            } catch {
                log.error("discovery failed: \(String(describing: error), privacy: .public)")
                discoveryStatus = (error as? URLError) != nil
                    ? "İnternete ulaşılamadı." : "Bu sefer iyi sesli bir şey bulunamadı, tekrar dene."
            }
            discovering = false
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discovering = false
        discoveryStatus = nil
    }

    func open(_ discovery: Discovery) {
        if !NSWorkspace.shared.open(discovery.musicURL) { NSWorkspace.shared.open(discovery.url) }
    }

    func setDiscoverVocalsOnly(_ on: Bool) {
        discoverVocalsOnly = on
        defaults.set(on, forKey: Key.discoverVocalsOnly)
    }

    func setDiscoverAutoOpen(_ on: Bool) {
        discoverAutoOpen = on
        defaults.set(on, forKey: Key.discoverAutoOpen)
    }

    /// Shows a mode without saving it (UI rendering).
    func previewVisualizer(_ mode: Visualizer) { visualizer = mode }

    func setVisualizer(_ mode: Visualizer) {
        visualizer = mode
        defaults.set(mode.rawValue, forKey: Key.visualizer)
    }

    func update(_ change: (inout EQDesign) -> Void) {
        guard var design else { return }
        change(&design)
        self.design = design
        defaults.set(design.eqEnabled, forKey: Key.eqEnabled)
        defaults.set(design.levelMatch, forKey: Key.levelMatch)
        defaults.set(design.strength, forKey: Key.strength)
        defaults.set(design.bassDb, forKey: Key.bass)
        defaults.set(design.trebleDb, forKey: Key.treble)
        defaults.set(design.adaptEnabled, forKey: Key.adaptEnabled)
        defaults.set(design.adaptStrength, forKey: Key.adaptStrength)
        defaults.set(design.tone.rawValue, forKey: Key.tone)
        defaults.set(design.loudnessCompensation, forKey: Key.loudnessCompensation)
        engine.apply(design)
        status = engine.refreshStatus()
    }

    // MARK: - L2 loudness compensation

    private func volumeChanged() {
        guard let monitor = volumeMonitor else { return }
        if !monitor.muted { volumeDb = monitor.volumeDb }
        if referenceVolumeDb == nil, let volumeDb {
            referenceVolumeDb = min(volumeDb + Self.defaultReferenceHeadroomDb, 0)
            defaults.set(referenceVolumeDb, forKey: Key.referenceVolumeDb)
        }
        applyListeningOffset()
    }

    /// "This is my loud, full-quality level": no compensation here, more below it.
    func setReferenceToCurrentVolume() {
        guard let volumeDb else { return }
        referenceVolumeDb = volumeDb
        defaults.set(volumeDb, forKey: Key.referenceVolumeDb)
        applyListeningOffset()
    }

    private func applyListeningOffset() {
        guard var design else { return }
        let offset = volumeDb.flatMap { v in referenceVolumeDb.map { v - $0 } }
        log.info("volume \(self.volumeDb ?? .nan) dB, reference \(self.referenceVolumeDb ?? .nan) dB, muted=\(self.volumeMonitor?.muted ?? false), device='\(self.volumeMonitor?.deviceName ?? "-", privacy: .public)'")
        guard design.listeningOffsetDb != offset else { return }
        design.listeningOffsetDb = offset
        self.design = design
        engine.apply(design)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginItemError = "Sistem Ayarları → Genel → Giriş Öğeleri'nden onay gerekiyor."
        }
    }

    private func loadDesign() {
        guard let url = Bundle.main.url(forResource: "s12-ultra", withExtension: "json") else {
            profileError = "s12-ultra.json pakette yok"
            return
        }
        do {
            var design = EQDesign(profile: try Profile.load(from: url),
                                  strength: defaults.object(forKey: Key.strength) as? Double)
            design.eqEnabled = defaults.bool(forKey: Key.eqEnabled)
            design.levelMatch = defaults.bool(forKey: Key.levelMatch)
            design.bassDb = defaults.double(forKey: Key.bass)
            design.trebleDb = defaults.double(forKey: Key.treble)
            design.adaptEnabled = defaults.bool(forKey: Key.adaptEnabled)
            design.adaptStrength = defaults.double(forKey: Key.adaptStrength)
            design.tone = EQDesign.Tone(rawValue: defaults.string(forKey: Key.tone) ?? "") ?? .natural
            design.loudnessCompensation = defaults.bool(forKey: Key.loudnessCompensation)
            self.design = design
            engine.apply(design)
        } catch {
            profileError = String(describing: error)
        }
    }

    // MARK: - Spectrum (only while the popover is visible)

    func setSpectrumVisible(_ visible: Bool) {
        spectrumTimer?.invalidate()
        spectrumTimer = nil
        guard visible else { return }
        let timer = Timer(timeInterval: 1.0 / ArtFrame.frameRate, repeats: true) { _ in
            MainActor.assumeIsolated { self.updateSpectrum() }
        }
        RunLoop.main.add(timer, forMode: .common)
        spectrumTimer = timer
        status = engine.refreshStatus()
    }

    private func updateSpectrum() {
        guard status.state == .running, status.deviceSampleRate > 0 else {
            inputSpectrum = []
            outputSpectrum = []
            art = ArtFrame()
            return
        }
        inputSpectrum = smoothed(inputSpectrum, analyze(engine.kernel.inputHistory))
        outputSpectrum = smoothed(outputSpectrum, analyze(engine.kernel.outputHistory))
        updateArt()
    }

    /// Output levels for the art modes: 30 Hz – 16 kHz, tilted up so the treble is not dwarfed
    /// by the bass, scaled 0…1 against a slowly falling ceiling so quiet music still moves.
    private func updateArt() {
        let bands = ArtFrame.bandRange.clamped(to: 0..<outputSpectrum.count)
        guard !bands.isEmpty else { art = ArtFrame(); return }
        let tilted = bands.map { outputSpectrum[$0] + ArtFrame.tiltDbPerOctave * Float(log2(analyzer.centers[$0] / 1000)) }
        artCeilingDb = max(tilted.max()!, artCeilingDb - ArtFrame.ceilingFallDb, ArtFrame.minCeilingDb)
        let levels = tilted.map { min(max(($0 - artCeilingDb + ArtFrame.rangeDb) / ArtFrame.rangeDb, 0), 1) }
        var next = art
        next.peaks = next.peaks.count == levels.count
            ? zip(next.peaks, levels).map { max($1, $0 - ArtFrame.peakFall) } : levels
        next.levels = levels
        func mean(_ range: ClosedRange<Double>) -> Float {
            let picked = zip(bands, levels).filter { range.contains(analyzer.centers[$0.0]) }.map(\.1)
            return picked.isEmpty ? 0 : picked.reduce(0, +) / Float(picked.count)
        }
        let bass = mean(0...120)
        // A beat: bass jumps well above its recent average.
        if bass - next.bassAverage > 0.12, next.beat < 0.5 { next.beat = 1 } else { next.beat *= 0.86 }
        next.bassAverage += (bass - next.bassAverage) * 0.1
        next.bass = bass
        next.mid = mean(250...2500)
        next.treble = mean(4000...20_000)
        let dt = 1 / ArtFrame.frameRate
        next.time += dt
        next.travel += dt * (0.25 + 2.5 * Double(bass) + 1.5 * Double(next.beat))
        artFrames += 1
        if artFrames % 3 == 0 {
            next.history.append(levels)
            if next.history.count > ArtFrame.historyLength { next.history.removeFirst() }
        }
        art = next
    }

    private func analyze(_ ring: SampleRing) -> [Float] {
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard ring.copyLatest(analyzer.size, into: buffer.baseAddress!) else { return [] }
            return analyzer.analyze(buffer.baseAddress!, sampleRate: status.deviceSampleRate)
        }
    }

    /// Fast attack, slow decay, like a meter.
    private func smoothed(_ old: [Float], _ new: [Float]) -> [Float] {
        guard old.count == new.count else { return new }
        return zip(old, new).map { o, n in n > o ? n : o + (n - o) * 0.175 }
    }

    // MARK: - Preview

    /// Fake live data so the UI can be rendered to an image without audio.
    func loadPreviewData() {
        status.state = .running
        discoveries = [
            Discovery(id: 1, title: "Örnek Keşif", artist: "Az Bilinen Sanatçı", genre: "ethio-jazz", storeGenre: "Jazz",
                      url: URL(string: "https://music.apple.com/tr/album/x/1?i=1")!, score: 78, plrDb: 11, issues: []),
            Discovery(id: 2, title: "Başka Şarkı", artist: "Biri", genre: "dub techno", storeGenre: "Electronic",
                      url: URL(string: "https://music.apple.com/tr/album/x/1?i=2")!, score: 64, plrDb: 8, issues: ["bas zayıf"]),
        ]
        discoveryStatus = "Tür: shoegaze · 2. aday ölçülüyor…"
        status.outputDeviceName = "External Headphones"
        status.deviceSampleRate = 96_000
        status.bufferFrames = 256
        status.measuredLatencyMs = 58.2
        volumeDb = -16
        referenceVolumeDb = -6
        design?.listeningOffsetDb = -10
        adaptation.libraryTracks = 12
        adaptation.usesLibraryTarget = true
        adaptation.phase = .adapting
        adaptation.correction = AdaptiveCorrection(gains: [-2.5, -1, 0.5, 0.8, -1.5, -2], presenceReduction: 0.3)
        adaptation.title = "Örnek Şarkı"
        adaptation.artist = "Sanatçı"
        adaptation.ownSeconds = 84
        adaptation.playing = true
        adaptation.features.seconds = 84
        adaptation.features.integratedLufs = -8.9
        adaptation.features.plrDb = 9.4
        adaptation.features.crestDb = 11.2
        adaptation.features.ltasPower = ThirdOctave.centers.map { pow($0 / 1000, -0.35) * ThirdOctave.bandwidths[0] }
        design?.adaptive = adaptation.correction
        if let design { status.settings = design.settings(sampleRate: 96_000) }
        let bands = design?.bands(sampleRate: 96_000) ?? []
        inputSpectrum = analyzer.centers.map { f in
            Float(-30 - 4.5 * log2(max(f, 40) / 1000) - (f > 12_000 ? (f - 12_000) / 800 : 0))
        }
        outputSpectrum = zip(inputSpectrum, analyzer.centers).map { level, f in
            level + Float(EQDesign.responseDb(bands, at: f, sampleRate: 96_000) + status.settings.preampDb)
        }
        // A moving fake so the history-based art modes have something to draw.
        let base = outputSpectrum
        for frame in 0..<(3 * ArtFrame.historyLength) {
            let t = Double(frame) / 8
            outputSpectrum = zip(base, analyzer.centers).map { level, f in
                let x = log2(f / 20)
                return level + Float(9 * sin(x * 1.7 + t) * cos(x * 0.6 - t * 0.7) + 6 * sin(t * 2.3) * exp(-x / 3))
            }
            updateArt()
        }
    }
}
