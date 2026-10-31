import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status) '\(fourCC(status))')" }
}

func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
}

private func fourCC(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let bytes = [24, 16, 8, 0].map { UInt8((u >> $0) & 0xFF) }
    return bytes.allSatisfy({ (32...126).contains($0) }) ? String(decoding: bytes, as: UTF8.self) : "\(s)"
}

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> Self {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func output(_ selector: AudioObjectPropertySelector) -> Self {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func read<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var address = address
        var value = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value),
                  "read '\(address.mSelector)' of #\(self)")
        return value
    }

    func readArray<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, of _: T.Type, zero: T) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "size of '\(address.mSelector)'")
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &values), "read '\(address.mSelector)'")
        return values
    }

    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "read string '\(address.mSelector)'")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(.global(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID.unknown)
    }

    var uid: String { (try? readString(.global(kAudioDevicePropertyDeviceUID))) ?? "" }
    var name: String { (try? readString(.global(kAudioObjectPropertyName))) ?? "?" }
    var manufacturer: String { (try? readString(.global(kAudioObjectPropertyManufacturer))) ?? "" }
    var nominalSampleRate: Double { (try? read(.global(kAudioDevicePropertyNominalSampleRate), default: 0.0)) ?? 0 }
    var isAlive: Bool { ((try? read(.global(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0) != 0 }

    func uint32(_ address: AudioObjectPropertyAddress) -> UInt32 {
        (try? read(address, default: UInt32(0))) ?? 0
    }

    /// Output-side latency in frames: device latency + safety offset + IO buffer + first stream latency.
    var outputLatencyFrames: UInt32 {
        var total = uint32(.output(kAudioDevicePropertyLatency))
            + uint32(.output(kAudioDevicePropertySafetyOffset))
            + uint32(.global(kAudioDevicePropertyBufferFrameSize))
        if let stream = try? readArray(.output(kAudioDevicePropertyStreams), of: AudioStreamID.self, zero: 0).first {
            total += stream.uint32(.global(kAudioStreamPropertyLatency))
        }
        return total
    }

    // MARK: Processes

    static func processObject(pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }

    static func processObjects() -> [AudioObjectID] {
        (try? AudioObjectID.system.readArray(.global(kAudioHardwarePropertyProcessObjectList),
                                             of: AudioObjectID.self, zero: .unknown)) ?? []
    }

    var processBundleID: String { (try? readString(.global(kAudioProcessPropertyBundleID))) ?? "" }
    var processIsRunningOutput: Bool { uint32(.global(kAudioProcessPropertyIsRunningOutput)) != 0 }
}

/// A property listener that removes itself when released.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
