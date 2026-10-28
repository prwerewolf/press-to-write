import Foundation
import CoreAudio

public struct AudioInputDevice: Identifiable, Equatable {
    public let id: UInt32
    public let uid: String
    public let name: String

    public init(id: UInt32, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

public enum MicrophoneError: LocalizedError {
    case selectedUnavailable
    case noDefaultInput
    case cannotSelectDevice
    case invalidFormat
    case disconnected
    case recordingInProgress

    public var errorDescription: String? {
        switch self {
        case .selectedUnavailable:
            return "Your selected microphone is unavailable. Reconnect it or choose another microphone in Settings."
        case .noDefaultInput:
            return "No microphone is available. Connect a microphone and try again."
        case .cannotSelectDevice:
            return "Unable to use this microphone. Choose another microphone in Settings."
        case .invalidFormat:
            return "This microphone has no usable audio input. Reconnect it or choose another microphone."
        case .disconnected:
            return "The microphone changed or disconnected. Check your microphone and start again."
        case .recordingInProgress:
            return "Finish your dictation before testing the microphone."
        }
    }
}

/// Resolve the preference afresh for every capture. A saved UID never silently
/// falls back to a different microphone when the chosen device disappears.
public enum AudioInputSelection {
    public static func resolve(
        selectedUID: String,
        devices: [AudioInputDevice],
        systemDefaultID: UInt32?
    ) throws -> AudioInputDevice {
        if !selectedUID.isEmpty {
            guard let device = devices.first(where: { $0.uid == selectedUID }) else {
                throw MicrophoneError.selectedUnavailable
            }
            return device
        }
        guard let defaultID = systemDefaultID,
              let device = devices.first(where: { $0.id == defaultID }) else {
            throw MicrophoneError.noDefaultInput
        }
        return device
    }

    /// Ordered capture attempts for one recording or level test. `nil` stands for
    /// the unconfigured AUHAL default input.
    ///
    /// An explicit choice yields exactly that device or an error, so dictation
    /// never records from a microphone the user did not pick. Only "System
    /// Default" may fall back, because the default can name an input that cannot
    /// start (for example an unreachable Continuity iPhone).
    public static func captureAttempts(
        selectedUID: String,
        devices: [AudioInputDevice],
        systemDefaultID: UInt32?
    ) throws -> [AudioInputDevice?] {
        if !selectedUID.isEmpty {
            return [try resolve(selectedUID: selectedUID, devices: devices, systemDefaultID: systemDefaultID)]
        }
        return systemDefaultCascade(devices: devices, systemDefaultID: systemDefaultID).map { Optional($0) } + [nil]
    }

    /// The system default first, then the built-in microphone, then any other input.
    static func systemDefaultCascade(
        devices: [AudioInputDevice],
        systemDefaultID: UInt32?
    ) -> [AudioInputDevice] {
        var result: [AudioInputDevice] = []
        var seenIDs = Set<UInt32>()

        if let defaultID = systemDefaultID,
           let primary = devices.first(where: { $0.id == defaultID }) {
            result.append(primary)
            seenIDs.insert(primary.id)
        }

        if let builtIn = devices.first(where: {
            $0.uid == "BuiltInMicrophoneDevice" ||
            $0.uid.localizedCaseInsensitiveContains("built-in") ||
            $0.uid.localizedCaseInsensitiveContains("builtin") ||
            $0.name.localizedCaseInsensitiveContains("built-in") ||
            $0.name.localizedCaseInsensitiveContains("built in") ||
            $0.name.localizedCaseInsensitiveContains("macbook")
        }), !seenIDs.contains(builtIn.id) {
            result.append(builtIn)
            seenIDs.insert(builtIn.id)
        }

        for dev in devices where !seenIDs.contains(dev.id) {
            result.append(dev)
            seenIDs.insert(dev.id)
        }

        return result
    }
}

/// Core Audio enumeration does not open an input stream or request microphone access.
public enum AudioInputCatalog {
    public static func devices() -> [AudioInputDevice] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: stringProperty(id, selector: kAudioObjectPropertyName) ?? "Microphone"
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func defaultDeviceID() -> UInt32? {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio transfers ownership for both Name and DeviceUID properties.
        return value?.takeRetainedValue() as String?
    }

    private static func hasInputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }
}
