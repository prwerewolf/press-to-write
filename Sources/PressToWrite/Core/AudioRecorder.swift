import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

enum AudioCaptureConfigurationAction: Equatable {
    case unchanged
    case restart
    case fail
}

public final class AudioRecorder: NSObject {
    public static let shared = AudioRecorder()

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var isRecordingInternal = false
    private var isTestingInternal = false
    private var captureToken: UUID?
    private var captureGate: CaptureGate?
    private var configurationObserver: NSObjectProtocol?
    private var testFailure: ((Error) -> Void)?

    public var onAudioLevel: ((Float) -> Void)?
    /// Delivered on the main queue after capture has stopped. The caller owns
    /// removal of the incomplete WAV and resetting the dictation interface.
    public var onRecordingError: ((Error, URL?) -> Void)?

    public var selectedInputUID: String {
        get { MicrophoneController.shared.selectedInputUID }
        set { MicrophoneController.shared.selectedInputUID = newValue }
    }

    public var isRecording: Bool { isRecordingInternal }

    private override init() {
        super.init()
    }

    public func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    public var hasPermission: Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Starts a 16 kHz mono PCM recording using the best available input device with automatic fallback.
    public func startRecording(onPCM16: ((Data) -> Void)? = nil) throws -> URL {
        if isRecordingInternal, let existingURL = tempFileURL { return existingURL }
        MicrophoneController.shared.stopTest()

        let microphone = MicrophoneController.shared
        microphone.refreshDevices()
        // Throws when an explicitly chosen microphone is not connected.
        let attempts = try AudioInputSelection.captureAttempts(
            selectedUID: microphone.selectedInputUID,
            devices: microphone.availableInputs,
            systemDefaultID: microphone.systemDefaultID
        )

        var lastError: Error?
        for candidate in attempts {
            do {
                let url = try attemptStartCapture(device: candidate, onPCM16: onPCM16)
                return url
            } catch {
                lastError = error
                NSLog("[Press To Write] Audio capture candidate %@ failed: %@", candidate?.name ?? "AUHAL default", error.localizedDescription)
                continue
            }
        }

        throw lastError ?? MicrophoneError.cannotSelectDevice
    }

    private func attemptStartCapture(device: AudioInputDevice?, onPCM16: ((Data) -> Void)?) throws -> URL {
        let (engine, resolvedDevice, inputFormat) = try makeInputEngine(device: device)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("presstowrite_\(UUID().uuidString).wav")
        let token = UUID()
        let gate = CaptureGate()
        var tapInstalled = false

        do {
            let converter = try Self.makeWhisperConverter(from: inputFormat)
            let whisperFormat = converter.outputFormat

            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: whisperFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            audioEngine = engine
            audioFile = file
            tempFileURL = outputURL
            captureToken = token
            captureGate = gate
            isRecordingInternal = true

            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self, weak file] buffer, _ in
                guard let self else { return }
                gate.performWhileActive {
                    guard let file else { return }
                    let level = Self.calculateAudioLevel(buffer: buffer)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.captureToken == token else { return }
                        self.onAudioLevel?(level)
                    }

                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (16000.0 / inputFormat.sampleRate)) + 64
                    guard let converted = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else { return }
                    var conversionError: NSError?
                    var consumed = false
                    converter.convert(to: converted, error: &conversionError) { _, status in
                        if consumed {
                            status.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        status.pointee = .haveData
                        return buffer
                    }
                    if let conversionError {
                        self.reportFailure(conversionError, token: token)
                        return
                    }
                    if converted.frameLength > 0 {
                        do {
                            try file.write(from: converted)
                            if let onPCM16, let samples = converted.int16ChannelData?[0] {
                                onPCM16(Data(bytes: samples, count: Int(converted.frameLength) * 2))
                            }
                        }
                        catch { self.reportFailure(error, token: token) }
                    }
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            watchConfiguration(engine, device: resolvedDevice, format: inputFormat, token: token)
            MicrophoneController.shared.recordingStarted(device: resolvedDevice)
            return outputURL
        } catch {
            gate.close()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            audioEngine = nil
            audioFile = nil
            tempFileURL = nil
            captureToken = nil
            captureGate = nil
            isRecordingInternal = false
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    public func stopRecording() -> URL? {
        guard isRecordingInternal else { return nil }
        isRecordingInternal = false
        endCapture()
        audioFile = nil
        let url = tempFileURL
        tempFileURL = nil
        MicrophoneController.shared.recordingStopped()
        return url
    }

    /// Only computes levels in memory: no file, conversion, or transcription.
    func startMicrophoneTest(
        onLevel: @escaping (Float) -> Void,
        onFailure: @escaping (Error) -> Void
    ) throws -> AudioInputDevice {
        guard !isRecordingInternal else { throw MicrophoneError.recordingInProgress }
        stopMicrophoneTest()
        let microphone = MicrophoneController.shared
        microphone.refreshDevices()
        let attempts = try AudioInputSelection.captureAttempts(
            selectedUID: microphone.selectedInputUID,
            devices: microphone.availableInputs,
            systemDefaultID: microphone.systemDefaultID
        )

        var lastError: Error?
        for candidate in attempts {
            do {
                let (engine, device, inputFormat) = try makeInputEngine(device: candidate)
                let token = UUID()
                let gate = CaptureGate()
                audioEngine = engine
                captureToken = token
                captureGate = gate
                testFailure = onFailure
                isTestingInternal = true
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                    gate.performWhileActive {
                        let level = Self.calculateAudioLevel(buffer: buffer)
                        DispatchQueue.main.async { [weak self] in
                            guard self?.captureToken == token else { return }
                            onLevel(level)
                        }
                    }
                }
                engine.prepare()
                try engine.start()
                watchConfiguration(engine, device: device, format: inputFormat, token: token)
                return device
            } catch {
                stopMicrophoneTest()
                lastError = error
                continue
            }
        }
        throw lastError ?? MicrophoneError.cannotSelectDevice
    }

    func stopMicrophoneTest() {
        guard isTestingInternal else { return }
        isTestingInternal = false
        endCapture()
        testFailure = nil
    }

    static func makeWhisperConverter(from inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw MicrophoneError.invalidFormat
        }
        // Include every input channel. The default remap can discard speech
        // from the second input of a stereo microphone or audio interface.
        converter.downmix = true
        return converter
    }

    private func makeInputEngine(device: AudioInputDevice?) throws -> (AVAudioEngine, AudioInputDevice, AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw MicrophoneError.cannotSelectDevice }

        let resolvedDevice: AudioInputDevice
        if let device {
            if Self.currentDeviceID(unit) != device.id {
                var id = AudioDeviceID(device.id)
                guard AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                ) == noErr else { throw MicrophoneError.cannotSelectDevice }
            }
            resolvedDevice = device
        } else {
            guard let curID = Self.currentDeviceID(unit) else { throw MicrophoneError.cannotSelectDevice }
            resolvedDevice = MicrophoneController.shared.availableInputs.first(where: { $0.id == curID })
                ?? AudioInputDevice(id: curID, uid: "default", name: "Default Microphone")
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.invalidFormat }
        return (engine, resolvedDevice, format)
    }

    private static func currentDeviceID(_ unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &id, &size
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// A configuration notification also occurs while Core Audio finishes
    /// starting a healthy input. Abort only when capture cannot safely continue
    /// with the same device and the format installed on its tap/converter.
    static func configurationAction(
        expectedDevice: AudioInputDevice,
        currentDeviceID: UInt32?,
        availableDevices: [AudioInputDevice],
        expectedFormat: AVAudioFormat,
        currentFormat: AVAudioFormat,
        isRunning: Bool
    ) -> AudioCaptureConfigurationAction {
        guard currentDeviceID == expectedDevice.id,
              availableDevices.contains(where: { $0.id == expectedDevice.id && $0.uid == expectedDevice.uid }),
              expectedFormat.isEqual(currentFormat) else { return .fail }
        return isRunning ? .unchanged : .restart
    }

    private func watchConfiguration(
        _ engine: AVAudioEngine, device: AudioInputDevice, format: AVAudioFormat, token: UUID
    ) {
        var attemptedRestart = false
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak engine] _ in
            guard let self, let engine, self.captureToken == token else { return }
            let input = engine.inputNode
            let action = Self.configurationAction(
                expectedDevice: device,
                currentDeviceID: input.audioUnit.flatMap(Self.currentDeviceID),
                availableDevices: AudioInputCatalog.devices(),
                expectedFormat: format,
                currentFormat: input.outputFormat(forBus: 0),
                isRunning: engine.isRunning
            )
            switch action {
            case .unchanged:
                return
            case .restart:
                // Core Audio can stop the engine for a graph update even when
                // the selected input and PCM format are unchanged. One restart
                // is safe; a repeated stop is surfaced as an input failure.
                if !attemptedRestart {
                    attemptedRestart = true
                    do {
                        engine.prepare()
                        try engine.start()
                        if engine.isRunning { return }
                    } catch {
                        self.reportFailure(error, token: token)
                        return
                    }
                }
                self.reportFailure(MicrophoneError.disconnected, token: token)
            case .fail:
                self.reportFailure(MicrophoneError.disconnected, token: token)
            }
        }
    }

    private func reportFailure(_ error: Error, token: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureToken == token else { return }
            if self.isRecordingInternal {
                let url = self.stopRecording()
                if let callback = self.onRecordingError {
                    callback(error, url)
                } else if let url {
                    try? FileManager.default.removeItem(at: url)
                }
            } else if self.isTestingInternal {
                let callback = self.testFailure
                self.stopMicrophoneTest()
                callback?(error)
            }
        }
    }

    private func endCapture() {
        captureToken = nil
        captureGate?.close()
        captureGate = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private static func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        // A multi-channel interface may have speech on a channel other than 1.
        var peakRMS: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var rms: Float = 0
            if buffer.format.isInterleaved {
                vDSP_rmsqv(
                    channels[0].advanced(by: channel),
                    vDSP_Stride(buffer.format.channelCount),
                    &rms,
                    vDSP_Length(buffer.frameLength)
                )
            } else {
                vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(buffer.frameLength))
            }
            peakRMS = max(peakRMS, rms)
        }
        let db = 20 * log10(max(peakRMS, 0.00001))
        return (max(-50, min(0, db)) + 50) / 50
    }
}

/// Closing the gate waits for any in-flight buffer write and prevents further
/// tap work, so the WAV is complete before stopRecording returns its URL.
private final class CaptureGate {
    private let lock = NSLock()
    private var active = true

    func performWhileActive(_ capture: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        capture()
    }

    func close() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
