import EQCore
import Foundation
import os

/// What the UI shows about L3 and the analysis. Derived numbers only.
struct AdaptationSnapshot: Sendable {
    var phase = AdaptationController.Phase.learning
    var correction = AdaptiveCorrection()
    var features = TrackFeatures()
    /// Gated audio seconds of this track heard in this play.
    var ownSeconds = 0.0
    var title: String?
    var artist: String?
    var fromCache = false
    var trackChanges = 0
    var lastChange: String?
    var playing = false
    var cachedTracks = 0
    /// Tracks (≥ 60 s analysed) behind the library target; it is used from `minLibraryTracks` on.
    var libraryTracks = 0
    var usesLibraryTarget = false
}

/// Runs the analysis off the main thread: pulls the pre-EQ mid/side history out of the
/// kernel's rings every 100 ms, feeds `TrackAnalyzer`, and every 0.5 s steps the
/// `AdaptationController` and reports a snapshot to the main actor.
@MainActor
final class AdaptationService {
    private let worker: Worker
    var onUpdate: ((AdaptationSnapshot) -> Void)?

    init(kernel: RenderKernel) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("S12AdaptiveEQ")
        worker = Worker(kernel: kernel, cachePath: dir.appendingPathComponent("tracks.sqlite").path)
        worker.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onUpdate?(snapshot) } }
        }
        worker.start()
    }

    func setSampleRate(_ rate: Double) { worker.async { $0.setSampleRate(rate) } }

    /// Music.app reported a new track (or state). `authoritative`: metadata replaces audio-based
    /// track-change detection (capturing Music.app only).
    func noteTrack(_ track: NowPlaying.Track, authoritative: Bool) {
        worker.async { $0.noteTrack(track, authoritative: authoritative) }
    }

    func setMetadataAuthoritative(_ on: Bool) { worker.async { $0.metadataAuthoritative = on } }

    func logState() { worker.async { $0.logState() } }

    func flush() { worker.sync { $0.saveTrack() } }
}

/// Lives on its own serial queue; every member is touched only there.
private final class Worker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.emiralan.s12-adaptive-eq.analysis", qos: .utility)
    private let log = Logger(subsystem: "com.emiralan.s12-adaptive-eq", category: "Adaptation")
    private let kernel: RenderKernel
    private let cache: TrackCache?
    private var timer: DispatchSourceTimer?
    var onSnapshot: (@Sendable (AdaptationSnapshot) -> Void)?

    private var sampleRate = 0.0
    private var analyzer: TrackAnalyzer?
    private var controller = AdaptationController()
    private var cursor = -1
    private var mid = [Float](repeating: 0, count: 8192)
    private var side = [Float](repeating: 0, count: 8192)
    private var droppedReads = 0
    /// Samples analysed since the last controller step: none means the engine is stopped and
    /// the analyzer's loudness is stale, so no time may pass for the controller.
    private var pulledSinceStep = 0

    private var track: NowPlaying.Track?
    private var cached: TrackFeatures?
    private var lastSaveSeconds = 0.0
    var metadataAuthoritative = false {
        didSet { analyzer?.detectsChanges = !metadataAuthoritative }
    }
    private var trackChanges = 0
    private var lastChange: String?
    private var ticks = 0
    private var lastStep = Date()

    private static let saveEverySeconds = 30.0
    private static let minSecondsToSave = 20.0
    private static let minLibrarySeconds = 60.0
    private var libraryTracks = 0

    init(kernel: RenderKernel, cachePath: String) {
        self.kernel = kernel
        cache = try? TrackCache(path: cachePath)
    }

    func async(_ body: @escaping @Sendable (Worker) -> Void) { queue.async { body(self) } }
    func sync(_ body: (Worker) -> Void) { queue.sync { body(self) } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [unowned self] in tick() }
        timer.resume()
        self.timer = timer
        if cache == nil { log.error("track cache could not be opened") }
        queue.async { [unowned self] in refreshTarget() }
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        let next = TrackAnalyzer(sampleRate: rate)
        if let analyzer { next.adopt(analyzer) } else { next.detectsChanges = !metadataAuthoritative }
        analyzer = next
        sampleRate = rate
        cursor = -1
    }

    private func tick() {
        pull()
        ticks += 1
        if ticks % 5 == 0 { step() }
    }

    /// Copies everything new from the rings into the analyzer.
    private func pull() {
        guard let analyzer else { return }
        let end = kernel.inputHistory.totalWritten
        if cursor < 0 || end - cursor > kernel.inputHistory.capacity / 2 {
            if cursor >= 0 { droppedReads += 1 }
            cursor = end
            return
        }
        while cursor < end {
            let n = min(mid.count, end - cursor)
            let ok = mid.withUnsafeMutableBufferPointer { m in
                side.withUnsafeMutableBufferPointer { s in
                    kernel.inputHistory.copy(from: cursor, count: n, into: m.baseAddress!)
                        && kernel.sideHistory.copy(from: cursor, count: n, into: s.baseAddress!)
                }
            }
            guard ok else { droppedReads += 1; cursor = end; return }
            let reason = mid.withUnsafeBufferPointer { m in
                side.withUnsafeBufferPointer { s in analyzer.process(mid: m.baseAddress!, side: s.baseAddress!, count: n) }
            }
            cursor += n
            pulledSinceStep += n
            if let reason { audioDetectedChange(reason) }
        }
    }

    private func step() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastStep), 2)
        lastStep = now
        guard let analyzer else { return }
        let own = analyzer.features
        let playing = pulledSinceStep > 0 && analyzer.isActive
        pulledSinceStep = 0
        let features = cached.map { $0.merged(with: own) } ?? own
        controller.update(features: features, ownSeconds: own.seconds, dt: playing ? elapsed : 0)
        if track != nil, own.seconds - lastSaveSeconds >= Self.saveEverySeconds { saveTrack() }

        var s = AdaptationSnapshot()
        s.phase = controller.phase
        s.correction = controller.current
        s.features = features
        s.ownSeconds = own.seconds
        s.title = track?.title
        s.artist = track?.artist
        s.fromCache = cached != nil
        s.trackChanges = trackChanges
        s.lastChange = lastChange
        s.playing = playing
        s.cachedTracks = cache?.count ?? 0
        s.libraryTracks = libraryTracks
        s.usesLibraryTarget = controller.target != nil
        onSnapshot?(s)
    }

    // MARK: Track changes

    func noteTrack(_ new: NowPlaying.Track, authoritative: Bool) {
        metadataAuthoritative = authoritative
        guard new.key != track?.key else { return }
        saveTrack()
        track = new
        analyzer?.startNewTrack()
        beginTrack(reason: "metadata")
        log.notice("""
            track change (metadata): '\(new.title, privacy: .public)' — \(new.artist, privacy: .public), \
            \(new.durationSeconds, format: .fixed(precision: 0)) s, cached=\(self.cached != nil)
            """)
    }

    private func audioDetectedChange(_ reason: TrackAnalyzer.ChangeReason) {
        // The analyzer has already started the new track; its old data is gone, so nothing to save.
        track = nil
        beginTrack(reason: reason.rawValue)
        log.notice("track change (audio): \(reason.rawValue, privacy: .public), novelty \(self.analyzer?.lastNoveltyDb ?? 0, format: .fixed(precision: 1)) dB")
    }

    private func beginTrack(reason: String) {
        refreshTarget()
        cached = track.flatMap { cache?.entry(forKey: $0.key)?.features }
        controller.trackChanged(cached: cached)
        lastSaveSeconds = 0
        trackChanges += 1
        lastChange = reason
    }

    /// L3 aims at the average balance of the tracks analysed so far (once there are enough).
    private func refreshTarget() {
        controller.target = cache.flatMap { AdaptiveFit.libraryTarget($0.allFeatures(minSeconds: Self.minLibrarySeconds)) }
        libraryTracks = cache?.allFeatures(minSeconds: Self.minLibrarySeconds).count ?? 0
    }

    /// Stores the current track's measurement (merged with what was cached) if it is long enough.
    func saveTrack() {
        guard let track, let cache, let own = analyzer?.features, own.seconds >= Self.minSecondsToSave else { return }
        let features = cached.map { $0.merged(with: own) } ?? own
        do {
            try cache.store(.init(title: track.title, artist: track.artist, durationSeconds: track.durationSeconds,
                                  features: features))
            lastSaveSeconds = own.seconds
        } catch {
            log.error("cache store failed: \(String(describing: error), privacy: .public)")
        }
    }

    func logState() {
        guard let analyzer else { return }
        let f = analyzer.features
        let gains = controller.current.gains.map { String(format: "%+.2f", $0) }.joined(separator: " ")
        log.info("""
            adapt: phase=\(self.controller.phase.rawValue, privacy: .public) own=\(f.seconds, format: .fixed(precision: 0))s \
            tilt=\(f.tiltDbPerOctave, format: .fixed(precision: 2)) I=\(f.integratedLufs, format: .fixed(precision: 1)) \
            S=\(f.shortTermLufs, format: .fixed(precision: 1)) plr=\(f.plrDb, format: .fixed(precision: 1)) \
            crest=\(f.crestDb, format: .fixed(precision: 1)) width=\(f.width, format: .fixed(precision: 2)) \
            novelty=\(analyzer.lastNoveltyDb, format: .fixed(precision: 1)) full=[\(gains, privacy: .public)] \
            presence=\(self.controller.current.presenceReduction, format: .fixed(precision: 2)) \
            changes=\(self.trackChanges) dropped=\(self.droppedReads) metadata=\(self.metadataAuthoritative)
            """)
    }
}
