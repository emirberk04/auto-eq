import AppKit
import CoreAudio
import EQCore
import os

enum CaptureMode: String, CaseIterable {
    /// Only Music.app is tapped; everything else plays untouched.
    case music
    /// Every process except this app.
    case system
}

/// Owns the process tap, the private aggregate device (tap input + real output device as
/// sub-device) and the IO proc. Tap input, processing and device output all happen in one
/// IO callback, so the audio path needs no ring buffer and adds no latency beyond the HAL's.
@MainActor
final class TapEngine {
    enum State: Equatable {
        case stopped
        case waitingForSource
        case running
        case failed(String)
    }

    struct Status {
        var state: State = .stopped
        var outputDeviceName = ""
        var deviceSampleRate = 0.0
        var tapSampleRate = 0.0
        var bufferFrames: UInt32 = 0
        var latencyMs = 0.0
        /// IO-cycle distance (measured each callback) + real device output latency.
        var measuredLatencyMs = 0.0
        var overloads = 0
        var frameMismatches = 0
        var rebuilds = 0
        /// Source reports it is playing but the tap delivers only zeros, or the device never
        /// started calling us (seen when audio-capture permission is denied).
        var permissionSuspect = false
        /// The limiter reduced gain since the previous status refresh.
        var limiterActive = false
        var limitedFramesTotal = 0
        var settings = DSPSettings()
        var warnings: [String] = []
    }

    static let musicBundleID = "com.apple.Music"
    private static let silenceWarningSeconds = 3.0
    private var runningSince: Date?
    private static let defaultBufferFrames: UInt32 = 256

    private let log = Logger(subsystem: "com.emiralan.s12-adaptive-eq", category: "TapEngine")
    let kernel = RenderKernel()
    private var design: EQDesign?

    private(set) var mode: CaptureMode
    private(set) var status = Status()
    private var wantsRunning = false

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioObjectID.unknown
    private var tappedSources: [AudioObjectID] = []
    private var deviceOutputLatencyFrames: UInt32 = 0
    private var consecutiveFailures = 0
    private var loggedLimitedFrames = 0

    private var systemListeners: [PropertyListener] = []
    private var sessionListeners: [PropertyListener] = []
    private var rebuildWork: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    init(mode: CaptureMode) {
        self.mode = mode
    }

    // MARK: - Public control

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        installSystemListeners()
        build(reason: "start")
    }

    /// Fades out (50 ms) before tearing down so stopping never clicks.
    func stop(completion: (@MainActor () -> Void)? = nil) {
        wantsRunning = false
        rebuildWork?.cancel()
        systemListeners.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        fadeOutAndTearDown {
            self.status.state = .stopped
            completion?()
        }
    }

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode else { return }
        mode = newMode
        if wantsRunning { scheduleRebuild("mode changed", delay: 0) }
    }

    /// New EQ choices take effect immediately (smoothed on the IO thread).
    func apply(_ design: EQDesign) {
        self.design = design
        publishSettings(sampleRate: status.deviceSampleRate > 0 ? status.deviceSampleRate : 48_000)
    }

    private func publishSettings(sampleRate: Double) {
        let settings = design?.settings(sampleRate: sampleRate) ?? DSPSettings()
        status.settings = settings
        kernel.settings.publish(settings)
    }

    /// One log line with the health counters; used for long-running and sleep/wake tests.
    func logHealth() {
        let limitedBefore = loggedLimitedFrames
        let s = refreshStatus()
        loggedLimitedFrames = s.limitedFramesTotal
        let reduction = kernel.takeMaxLimiterReductionDb()
        let peaks = kernel.takePeaksDb()
        if s.limitedFramesTotal > limitedBefore, s.deviceSampleRate > 0 {
            let ms = Double(s.limitedFramesTotal - limitedBefore) / s.deviceSampleRate * 1000
            log.notice("""
                limiter: \(ms, format: .fixed(precision: 0)) ms limited since last report, \
                max reduction \(reduction, format: .fixed(precision: 2)) dB, \
                peaks in \(peaks.input, format: .fixed(precision: 2)) / EQ \(peaks.eq, format: .fixed(precision: 2)) dBFS, \
                preamp \(s.settings.preampDb, format: .fixed(precision: 2)) dB
                """)
        }
        log.info("""
            health: state=\(String(describing: s.state), privacy: .public) \
            frames=\(self.kernel.renderedFrames.load(ordering: .relaxed)) \
            silent=\(self.kernel.silentFrames.load(ordering: .relaxed)) \
            overloads=\(s.overloads) mismatches=\(s.frameMismatches) rebuilds=\(s.rebuilds) \
            gain=\(self.kernel.currentGain) permissionSuspect=\(s.permissionSuspect) \
            limited=\(s.limitedFramesTotal) eq=\(s.settings.eqEnabled) bands=\(s.settings.bandCount) \
            preamp=\(s.settings.preampDb, format: .fixed(precision: 2)) dry=\(s.settings.dryGainDb, format: .fixed(precision: 2)) \
            ioDistance=\(self.kernel.ioDistanceFrames.load(ordering: .relaxed)) \
            measuredLatencyMs=\(s.measuredLatencyMs, format: .fixed(precision: 1)) l2=\(self.design?.loudnessGains.bass ?? -1)/\(self.design?.loudnessGains.treble ?? -1) offset=\(self.design?.listeningOffsetDb ?? .nan)
            """)
    }

    /// Called periodically by the UI to refresh counters and the permission heuristic.
    func refreshStatus() -> Status {
        status.frameMismatches = kernel.frameMismatches.load(ordering: .relaxed)
        let limited = kernel.limitedFrames.load(ordering: .relaxed)
        status.limiterActive = limited > status.limitedFramesTotal
        status.limitedFramesTotal = limited
        if status.deviceSampleRate > 0 {
            let frames = kernel.ioDistanceFrames.load(ordering: .relaxed) + Int(deviceOutputLatencyFrames)
                + kernel.latencyFrames
            status.measuredLatencyMs = Double(frames) / status.deviceSampleRate * 1000
        }
        if status.state == .running, status.deviceSampleRate > 0 {
            let silentSeconds = Double(kernel.silentFrames.load(ordering: .relaxed)) / status.deviceSampleRate
            let stalled = kernel.renderedFrames.load(ordering: .relaxed) == 0
                && Date().timeIntervalSince(runningSince ?? Date()) > Self.silenceWarningSeconds
            status.permissionSuspect = stalled
                || (silentSeconds > Self.silenceWarningSeconds && sourceIsPlaying())
        } else {
            status.permissionSuspect = false
        }
        return status
    }

    // MARK: - Build / teardown

    private func build(reason: String) {
        guard wantsRunning else { return }
        log.info("build (\(reason, privacy: .public)), mode=\(self.mode.rawValue, privacy: .public)")
        tearDown()
        status = Status(overloads: status.overloads, rebuilds: status.rebuilds + 1)
        loggedLimitedFrames = 0
        status.warnings = environmentWarnings()

        do {
            outputDeviceID = try .defaultOutputDevice()
            guard outputDeviceID.isValid else { throw CoreAudioError(what: "no default output device", status: -1) }

            let sources = currentSources()
            if mode == .music && sources.isEmpty {
                status.state = .waitingForSource
                status.outputDeviceName = outputDeviceID.name
                log.info("Music.app has no audio process yet; waiting")
                installSessionListeners()
                return
            }
            tappedSources = sources

            try createTap(sources: sources)
            try createAggregate()
            try startIO()
            installSessionListeners()
            status.state = .running
            runningSince = Date()
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            // Right after a device switch the HAL is still reconfiguring and tap creation
            // returns no object; it succeeds a few hundred ms later. Back off after that.
            let delay = consecutiveFailures <= 3 ? 0.5 : 2.0
            log.notice("build attempt \(self.consecutiveFailures) failed, retry in \(delay)s: \(String(describing: error), privacy: .public)")
            tearDown()
            status.state = .failed(String(describing: error))
            scheduleRebuild("retry after failure", delay: delay)
        }
    }

    private func createTap(sources: [AudioObjectID]) throws {
        let description: CATapDescription
        switch mode {
        case .music:
            description = CATapDescription(stereoMixdownOfProcesses: sources)
            if #available(macOS 26.0, *) {
                // Re-attach automatically when Music.app is relaunched.
                description.bundleIDs = [Self.musicBundleID]
                description.isProcessRestoreEnabled = true
            }
        case .system:
            let ourProcess = AudioObjectID.processObject(pid: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ourProcess.isValid ? [ourProcess] : [])
            if #available(macOS 26.0, *), let ourBundle = Bundle.main.bundleIdentifier {
                // Our process object may not exist before our first IO; exclude by bundle ID too.
                description.bundleIDs = [ourBundle]
            }
        }
        description.uuid = UUID()
        description.name = "S12 Adaptive EQ"
        description.isPrivate = true
        // Muted only while our IO proc reads it: if we stop or crash, audio goes back to the device.
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &id), "AudioHardwareCreateProcessTap")
        // During device reconfiguration creation can "succeed" without an object.
        guard id.isValid else { throw CoreAudioError(what: "AudioHardwareCreateProcessTap returned no tap", status: -1) }
        tapID = id

        let format = try id.read(.global(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        status.tapSampleRate = format.mSampleRate
        log.info("tap #\(id) format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, flags \(format.mFormatFlags)")
        tapUUID = description.uuid.uuidString
    }

    private var tapUUID = ""

    private func createAggregate() throws {
        let outputUID = outputDeviceID.uid
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "S12 Adaptive EQ",
            kAudioAggregateDeviceUIDKey: "com.emiralan.s12-adaptive-eq.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var id = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "AudioHardwareCreateAggregateDevice")
        aggregateID = id

        for _ in 0..<30 where !id.isAlive {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard id.isAlive else { throw CoreAudioError(what: "aggregate device never became alive", status: -1) }
    }

    private func startIO() throws {
        // The tap itself reports ~1024 frames of safety offset, so the IO buffer is the
        // only latency we control. 256 frames: -5 ms vs. the default 512, still cheap.
        var bufferFrames = UInt32(UserDefaults.standard.integer(forKey: "ioBufferFrames"))
        if bufferFrames == 0 { bufferFrames = Self.defaultBufferFrames }
        var address = AudioObjectPropertyAddress.global(kAudioDevicePropertyBufferFrameSize)
        let bufferStatus = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames)
        if bufferStatus != noErr { log.error("setting buffer size \(bufferFrames) failed: \(bufferStatus)") }
        let sampleRate = aggregateID.nominalSampleRate
        publishSettings(sampleRate: sampleRate)
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)

        var proc: AudioDeviceIOProcID?
        let refCon = Unmanaged.passUnretained(kernel).toOpaque()
        try check(AudioDeviceCreateIOProcID(aggregateID, renderProc, refCon, &proc), "AudioDeviceCreateIOProcID")
        procID = proc
        try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart")

        let buffer = aggregateID.uint32(.global(kAudioDevicePropertyBufferFrameSize))
        let input = { (s: AudioObjectPropertySelector) in
            self.aggregateID.uint32(.init(mSelector: s, mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain))
        }
        let inLatency = input(kAudioDevicePropertyLatency), inSafety = input(kAudioDevicePropertySafetyOffset)
        let outLatency = aggregateID.uint32(.output(kAudioDevicePropertyLatency))
        let outSafety = aggregateID.uint32(.output(kAudioDevicePropertySafetyOffset))
        log.info("""
            latency frames: in \(inLatency)+\(inSafety) safety, buffer \(buffer), \
            out \(outLatency)+\(outSafety) safety, device out total \(self.outputDeviceID.outputLatencyFrames)
            """)
        // Input side (tap) + one IO cycle + output side of the aggregate.
        let frames = Double(inLatency + inSafety + buffer + outLatency + outSafety)
        deviceOutputLatencyFrames = outputDeviceID.outputLatencyFrames
        status.outputDeviceName = outputDeviceID.name
        status.deviceSampleRate = sampleRate
        status.bufferFrames = buffer
        status.latencyMs = sampleRate > 0 ? frames / sampleRate * 1000 : 0
        log.info("""
            running: out='\(self.status.outputDeviceName, privacy: .public)' \(sampleRate) Hz, \
            buffer \(buffer), est. latency \(self.status.latencyMs, format: .fixed(precision: 1)) ms
            """)
    }

    private func fadeOutAndTearDown(then done: @escaping @MainActor () -> Void) {
        guard procID != nil else {
            tearDown()
            done()
            return
        }
        kernel.setTargetGain(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + RenderKernel.rampSeconds + 0.03) {
            self.tearDown()
            done()
        }
    }

    private func tearDown() {
        sessionListeners.removeAll()
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = .unknown
        tapID = .unknown
        tappedSources = []
    }

    // MARK: - Sources

    private func currentSources() -> [AudioObjectID] {
        switch mode {
        case .music:
            return AudioObjectID.processObjects().filter { $0.processBundleID == Self.musicBundleID }
        case .system:
            return []
        }
    }

    private func sourceIsPlaying() -> Bool {
        let ours = Bundle.main.bundleIdentifier ?? ""
        return AudioObjectID.processObjects().contains { process in
            let bundle = process.processBundleID
            let relevant = mode == .music ? bundle == Self.musicBundleID : bundle != ours
            return relevant && process.processIsRunningOutput
        }
    }

    private func environmentWarnings() -> [String] {
        var warnings: [String] = []
        let eqMacRunning = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().contains("eqmac")
        }
        if eqMacRunning { warnings.append("eqMac çalışıyor: çifte EQ olur, kapat.") }
        if let device = try? AudioObjectID.defaultOutputDevice(),
           device.manufacturer.contains("Bitgapp") || device.name.contains("eqMac") {
            warnings.append("Varsayılan çıkış eqMac sanal cihazı; gerçek kulaklık çıkışını seç.")
        }
        return warnings
    }

    // MARK: - Change detection

    private func installSystemListeners() {
        systemListeners = [
            PropertyListener(.system, .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.scheduleRebuild("default output changed")
            },
            PropertyListener(.system, .global(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
                self?.processListChanged()
            },
        ].compactMap { $0 }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("wake from sleep", delay: 1) }
        }
    }

    private func installSessionListeners() {
        guard outputDeviceID.isValid else { return }
        var listeners: [PropertyListener?] = [
            PropertyListener(outputDeviceID, .global(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
                self?.scheduleRebuild("output sample rate changed")
            },
            PropertyListener(outputDeviceID, .output(kAudioDevicePropertyStreamConfiguration)) { [weak self] in
                self?.scheduleRebuild("output stream configuration changed")
            },
            PropertyListener(outputDeviceID, .global(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in
                self?.scheduleRebuild("output device alive changed")
            },
        ]
        if tapID.isValid {
            listeners.append(PropertyListener(tapID, .global(kAudioTapPropertyFormat)) { [weak self] in
                self?.scheduleRebuild("tap format changed")
            })
        }
        if aggregateID.isValid {
            listeners.append(PropertyListener(aggregateID, .global(kAudioDeviceProcessorOverload)) { [weak self] in
                self?.status.overloads += 1
            })
            listeners.append(PropertyListener(aggregateID, .global(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in
                self?.scheduleRebuild("aggregate died")
            })
        }
        sessionListeners = listeners.compactMap { $0 }
    }

    private func processListChanged() {
        guard mode == .music else { return }
        let sources = currentSources()
        if Set(sources) != Set(tappedSources) {
            // On macOS 26 the tap restores Music by bundle ID; still rebuild so the
            // aggregate's tap tracks the new process object.
            scheduleRebuild(sources.isEmpty ? "Music.app quit" : "Music.app process changed")
        }
    }

    private func scheduleRebuild(_ reason: String, delay: Double = 0.3) {
        guard wantsRunning else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.build(reason: reason) }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Real-time IO proc. Called on the HAL IO thread: no allocation, locks, logging or ARC
/// traffic (the kernel reference is borrowed, not retained).
private func renderProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ input: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ output: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ refCon: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let refCon else { return noErr }
    Unmanaged<RenderKernel>.fromOpaque(refCon)._withUnsafeGuaranteedRef {
        $0.noteTimes(input: inputTime, output: outputTime)
        $0.render(input: input, output: output)
    }
    return noErr
}
