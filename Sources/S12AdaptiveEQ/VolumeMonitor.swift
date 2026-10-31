import CoreAudio
import Foundation

/// Follows the default output device's volume (dB) for L2 loudness compensation. The volume
/// is applied after our processing, by the device, so it tells how loud the music plays.
@MainActor
final class VolumeMonitor {
    /// Current volume in dB, nil when the device has no readable volume (e.g. fixed-level DACs).
    private(set) var volumeDb: Double?
    private(set) var muted = false
    private(set) var deviceName = ""
    var onChange: (() -> Void)?

    private var device = AudioDeviceID.unknown
    private var deviceListener: PropertyListener?
    private var volumeListeners: [PropertyListener] = []

    init() {
        deviceListener = PropertyListener(.system, .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.attach()
        }
        attach()
    }

    private func attach() {
        device = (try? AudioObjectID.defaultOutputDevice()) ?? .unknown
        deviceName = device.isValid ? device.name : ""
        volumeListeners = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].compactMap {
            PropertyListener(device, .output($0)) { [weak self] in self?.read() }
        }
        read()
    }

    private func read() {
        var address = AudioObjectPropertyAddress.output(kAudioDevicePropertyVolumeDecibels)
        if device.isValid, AudioObjectHasProperty(device, &address) {
            volumeDb = (try? device.read(address, default: Float32(0))).map(Double.init)
        } else {
            volumeDb = nil
        }
        muted = ((try? device.read(.output(kAudioDevicePropertyMute), default: UInt32(0))) ?? 0) != 0
        onChange?()
    }
}
