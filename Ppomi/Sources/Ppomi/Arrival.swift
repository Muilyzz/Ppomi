// The arrival greeting's judgement: the phone just reconnected — is the person here, awake, and able to hear? shouldGreet is
// pure (ArrivalTests); the three probes below read the Mac (HID idle, screen lock, output volume) for it.
import AudioToolbox
import CoreGraphics
import Foundation
import IOKit

enum Arrival {
    /// 30 min since the last greeting, the person touched the Mac within a minute, screen unlocked, sound on, not 23:00–07:00.
    static func shouldGreet(now: Date, lastGreet: Date?, idleSeconds: Double, screenLocked: Bool, muted: Bool) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return now.timeIntervalSince(lastGreet ?? .distantPast) >= 1800 && idleSeconds < 60 && !screenLocked && !muted && (7..<23).contains(hour)
    }

    /// Seconds since the last keyboard/mouse event (IOHIDSystem's HIDIdleTime, nanoseconds). 0 when unreadable: assume present.
    static func idleSeconds() -> Double {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        let ns = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int ?? 0
        return Double(ns) / 1e9
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The default output device: volume 0 or mute on.
    static func muted() -> Bool {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 1; size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr, vol == 0 { return true }
        addr.mSelector = kAudioDevicePropertyMute
        var mute: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &mute) == noErr && mute != 0
    }
}
