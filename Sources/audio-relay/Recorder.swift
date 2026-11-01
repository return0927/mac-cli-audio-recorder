import AVFoundation
import CoreAudio
import Foundation

/// Records what's playing (whole system, or selected apps) via a Core Audio process tap.
/// The tap is *unmuted*, so audio keeps going to the current output device (AirPods,
/// audio interface, ...) untouched — we only receive a copy.
final class Recorder {
    /// nil = whole system. Otherwise a matcher re-evaluated whenever processes come and go
    /// (so e.g. a new Chrome helper process for a new tab gets picked up).
    private let matcher: (() -> [AudioObjectID])?

    private var tapDescription: CATapDescription!
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "audio-relay.io", qos: .userInteractive)

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var _peak: Float = 0
    private var _frames: Int64 = 0
    private var _heardSound = false
    private var _writeError: Error?

    /// Start-on-sound: nil = record immediately.
    struct Trigger {
        /// Linear peak (0...1) a buffer must reach to start recording.
        var threshold: Float
        /// Seconds of audio kept from just before the trigger, so the attack isn't cut off.
        var preRoll: Double
    }
    private let trigger: Trigger?
    private var _triggeredAt: Date?
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    private(set) var format: AVAudioFormat!
    private(set) var tappedProcesses: [AudioObjectID] = []

    init(matcher: (() -> [AudioObjectID])?, trigger: Trigger? = nil) {
        self.matcher = matcher
        self.trigger = trigger
        if trigger == nil { _triggeredAt = Date() }
    }

    // MARK: - Stats (read from the UI timer)

    /// Peak since the last call, then resets.
    func takePeak() -> Float { lock.withLock { defer { _peak = 0 }; return _peak } }
    var framesWritten: Int64 { lock.withLock { _frames } }
    var heardSound: Bool { lock.withLock { _heardSound } }
    var writeError: Error? { lock.withLock { _writeError } }
    /// When recording actually started (nil while waiting for sound).
    var triggeredAt: Date? { lock.withLock { _triggeredAt } }

    // MARK: - Start / stop

    func start(writingTo url: URL) throws {
        // 1. Process tap
        if let matcher {
            tappedProcesses = matcher()
            tapDescription = CATapDescription(stereoMixdownOfProcesses: tappedProcesses)
        } else {
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "audio-relay"
        tapDescription.muteBehavior = .unmuted   // keep playing to AirPods / interface
        tapDescription.isPrivate = true

        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        var asbd = try getValue(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(what: "Unsupported tap format", status: -1)
        }
        format = fmt

        // 2. Private aggregate device containing only the tap. No real sub-device on purpose:
        //    adding AirPods / the interface would also pull in their microphone inputs
        //    (and switch AirPods into low-quality headset mode).
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "audio-relay",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // 3. Output file (format chosen by extension)
        file = try AVAudioFile(forWriting: url,
                               settings: Self.fileSettings(for: url, sampleRate: fmt.sampleRate,
                                                           channels: fmt.channelCount),
                               commonFormat: .pcmFormatFloat32,
                               interleaved: fmt.isInterleaved)

        // 4. IO callback: copy the tapped buffers into the file
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, input, _, _, _ in
            self?.handle(input)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")

        if matcher != nil { watchProcessList() }
    }

    func stop() {
        if let listener = processListListener {
            var addr = address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, .main, listener)
            processListListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Drain the IO queue, then release the file (finalizes the header / AAC packets).
        ioQueue.sync {}
        lock.withLock {
            if #available(macOS 15, *) { file?.close() }
            file = nil
        }
    }

    // MARK: - Internals

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }

        var peak: Float = 0
        for ab in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = ab.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(ab.mDataByteSize) / MemoryLayout<Float>.size {
                peak = max(peak, abs(samples[i]))
            }
        }

        lock.withLock {
            _peak = max(_peak, peak)
            guard let file else { return }

            if _triggeredAt == nil, let trigger {
                guard peak >= trigger.threshold else {
                    keepForPreRoll(buffer, seconds: trigger.preRoll)
                    return
                }
                _triggeredAt = Date()
                for b in preRollBuffers { write(b, to: file) }
                preRollBuffers = []
            }

            write(buffer, to: file)
            if peak > 0 { _heardSound = true }
        }
    }

    /// Call with `lock` held.
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: buffer)
            _frames += Int64(buffer.frameLength)
        } catch {
            _writeError = error
        }
    }

    /// Ring of the most recent `seconds` of audio (copied — the IO buffer is reused). Call with `lock` held.
    private func keepForPreRoll(_ buffer: AVAudioPCMBuffer, seconds: Double) {
        let limit = AVAudioFrameCount(seconds * format.sampleRate)
        guard limit > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sd = s.mData, let dd = d.mData else { continue }
            memcpy(dd, sd, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        preRollBuffers.append(copy)
        preRollFrames += copy.frameLength
        while let first = preRollBuffers.first, preRollFrames - first.frameLength >= limit {
            preRollFrames -= first.frameLength
            preRollBuffers.removeFirst()
        }
    }

    /// When matching an app, keep the tap's process list in sync as helper processes appear.
    private func watchProcessList() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTappedProcesses()
        }
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main, listener) == noErr {
            processListListener = listener
        }
    }

    private func refreshTappedProcesses() {
        guard let matcher, tapID != kAudioObjectUnknown else { return }
        let updated = matcher()
        guard !updated.isEmpty, Set(updated) != Set(tappedProcesses) else { return }
        tapDescription.processes = updated
        var addr = address(kAudioTapPropertyDescription)
        var desc: CATapDescription = tapDescription
        let status = withUnsafeMutablePointer(to: &desc) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                       UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { tappedProcesses = updated }
    }

    static func fileSettings(for url: URL, sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        switch url.pathExtension.lowercased() {
        case "wav", "wave", "aif", "aiff", "caf":
            let ext = url.pathExtension.lowercased()
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: ext.hasPrefix("aif"),
                AVLinearPCMIsNonInterleaved: false,
            ]
        default: // m4a / aac / mp4
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 256_000,
            ]
        }
    }
}
