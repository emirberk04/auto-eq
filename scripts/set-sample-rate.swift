// Sets the default output device's nominal sample rate (test helper for rate-change recovery).
// Usage: swift scripts/set-sample-rate.swift 48000
import CoreAudio
import Foundation

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device = AudioObjectID(0)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
var rate = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 48000
address.mSelector = kAudioDevicePropertyNominalSampleRate
let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
print(status == noErr ? "device #\(device) -> \(rate) Hz" : "failed: \(status)")
