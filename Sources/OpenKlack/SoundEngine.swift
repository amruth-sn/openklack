import AppKit
import AVFoundation
import os.log

let klog = Logger(subsystem: "dev.openklack", category: "app")

/// Low-latency sample player. A fixed pool of player nodes (each with its own
/// varispeed unit for per-keystroke pitch randomization) feeds a master EQ
/// (the Tone Pad's tilt filter) and the main mixer.
final class SoundEngine {
    private let engine = AVAudioEngine()
    // Voices fan into a submixer (EQ has only one input bus) before the EQ.
    private let submix = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private struct Voice {
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
    }

    private var voices: [Voice] = []
    private var nextVoice = 0
    private let voiceCount = 20

    /// Decoded buffers keyed by "<packId>/<relativePath>".
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var currentPack: SoundPack?
    private var packGain: Float = 1

    /// Master volume, 0...1.
    var volume: Float = 0.55 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    /// Pitch offset applied to every keystroke, in cents (Tone Pad X).
    var pitchOffsetCents: Float = 0
    /// Random pitch spread, in ± cents.
    var pitchVariationCents: Float = 60
    /// Stereo spread amount 0...1 (spatial feel; pans by key position).
    var stereoSpread: Float = 0.7

    init() {
        let lowShelf = eq.bands[0]
        lowShelf.filterType = .lowShelf
        lowShelf.frequency = 250
        lowShelf.gain = 0
        lowShelf.bypass = false
        let highShelf = eq.bands[1]
        highShelf.filterType = .highShelf
        highShelf.frequency = 3_000
        highShelf.gain = 0
        highShelf.bypass = false

        engine.attach(submix)
        engine.attach(eq)
        engine.connect(submix, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        for _ in 0..<voiceCount {
            let v = Voice()
            engine.attach(v.player)
            engine.attach(v.varispeed)
            engine.connect(v.player, to: v.varispeed, format: format)
            engine.connect(v.varispeed, to: submix, format: format)
            voices.append(v)
        }
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()

        // The engine stops itself when the output route changes (headphones,
        // Bluetooth, display sleep). Rebuild the output connection and restart.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            klog.notice("output configuration changed")
            self?.restart()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.restart()
        }
    }

    /// Re-negotiate the mixer→output connection (the hardware format may have
    /// changed) and get every voice playing again.
    private func restart() {
        engine.stop()
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        if hwFormat.sampleRate > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hwFormat)
        }
        requestLowLatencyIO()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            klog.error("engine restart failed: \(error, privacy: .public)")
            return
        }
        reviveVoices()
        klog.notice("engine restarted (hw \(hwFormat.sampleRate, privacy: .public) Hz, output latency \(self.outputLatency * 1000, privacy: .public) ms)")
    }

    func start() throws {
        guard !engine.isRunning else { return }
        requestLowLatencyIO()
        try engine.start()
        reviveVoices()
        klog.notice("engine started (output latency \(self.outputLatency * 1000, privacy: .public) ms)")
    }

    /// Hardware I/O cycle we ask for, in frames. The HAL default (512 frames,
    /// ~10.7 ms at 48 kHz) suits music playback, but a keystroke scheduled
    /// mid-cycle waits for the next one and then a full cycle more before it
    /// reaches the device: ~17 ms median from scheduleBuffer() to render.
    /// 128 frames brings that to ~5 ms and is still trivial for this graph.
    private static let ioBufferFrames: UInt32 = 128

    /// Applies to this process's I/O only; the device keeps serving other
    /// apps at their own sizes. Must run before the engine starts.
    private func requestLowLatencyIO() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = Self.ioBufferFrames
        let err = AudioUnitSetProperty(unit,
                                       kAudioDevicePropertyBufferFrameSize,
                                       kAudioUnitScope_Global,
                                       0,
                                       &frames,
                                       UInt32(MemoryLayout<UInt32>.size))
        if err != noErr {
            klog.error("could not set I/O buffer to \(frames, privacy: .public) frames: \(err, privacy: .public)")
        }
    }

    /// Time from a sample leaving the engine to it reaching the speaker:
    /// the device's own latency plus its safety offset. Bluetooth outputs
    /// report well over 100 ms here, which no buffer setting can recover.
    var outputLatency: TimeInterval {
        engine.outputNode.presentationLatency
    }

    /// After any engine stop→start cycle, player nodes report a stale
    /// `isPlaying == true` and `play()` alone is a no-op — they render
    /// silence forever. A stop()+play() per node fully revives them.
    private func reviveVoices() {
        for v in voices {
            v.player.stop()
            v.player.play()
        }
    }

    func stop() {
        engine.stop()
    }

    /// Tone Pad: x, y in -1...1. X darkens/brightens via shelf tilt, Y shifts pitch.
    func setTone(x: Float, y: Float) {
        eq.bands[0].gain = -x * 6
        eq.bands[1].gain = x * 6
        pitchOffsetCents = y * 250
    }

    // MARK: - Pack loading

    func load(pack: SoundPack) {
        var newBuffers: [String: AVAudioPCMBuffer] = [:]
        var files = Set<String>()
        for entry in pack.manifest.keys.values {
            entry.down.forEach { files.insert($0) }
            entry.up?.forEach { files.insert($0) }
        }
        for rel in files {
            let url = pack.url.appendingPathComponent(rel)
            if let buf = Self.decode(url: url, to: format) {
                newBuffers["\(pack.id)/\(rel)"] = buf
            } else {
                NSLog("OpenKlack: failed to decode \(url.path)")
            }
        }
        buffers = newBuffers
        currentPack = pack
        packGain = pow(10, (pack.manifest.gainDb ?? 0) / 20)
    }

    private static func decode(url: URL, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFormat = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: capacity),
              (try? file.read(into: src)) != nil else { return nil }
        if srcFormat == format { return src }
        guard let converter = AVAudioConverter(from: srcFormat, to: format) else { return nil }
        let ratio = format.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 64
        guard let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: dst, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return src
        }
        return error == nil ? dst : nil
    }

    // MARK: - Extras (shared one-off samples, e.g. the return-key ding)

    private var extras: [String: AVAudioPCMBuffer] = [:]

    /// Load loose samples from Sounds/_extras/<name>.(wav|mp3|caf|aiff).
    func loadExtras(from dir: URL) {
        extras.removeAll()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["wav", "mp3", "caf", "aiff", "m4a"].contains(url.pathExtension) {
            if let buf = Self.decode(url: url, to: format) {
                extras[url.deletingPathExtension().lastPathComponent] = buf
            }
        }
    }

    func playExtra(named name: String, gain: Float = 0.7) {
        guard let buffer = extras[name] else { return }
        play(buffer: buffer, cents: 0, pan: 0.2, gain: gain)
    }

    // MARK: - Playback

    /// Play a keystroke sound. `up` selects release samples; returns false if
    /// the pack has no sample for this class/direction.
    @discardableResult
    func playKey(keyClass: KeyClass, up: Bool, x: Float) -> Bool {
        guard let pack = currentPack else { return false }
        let candidates = pack.samples(for: keyClass, up: up)
        guard !candidates.isEmpty,
              let rel = candidates.randomElement(),
              let buffer = buffers["\(pack.id)/\(rel)"] else {
            if !up {
                klog.error("no sample for \(keyClass.rawValue, privacy: .public) in pack \(pack.id, privacy: .public)")
            }
            return false
        }
        if !engine.isRunning {
            klog.error("play requested but engine not running")
            return false
        }

        let cents = pitchOffsetCents + Float.random(in: -pitchVariationCents...pitchVariationCents)
        let pan = (x - 0.5) * 2 * 0.35 * stereoSpread
        let gain = packGain * (up ? 0.8 : 1.0)
        play(buffer: buffer, cents: cents, pan: pan, gain: gain)
        return true
    }

    private func play(buffer: AVAudioPCMBuffer, cents: Float, pan: Float, gain: Float) {
        guard engine.isRunning else { return }
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voiceCount
        voice.varispeed.rate = pow(2, cents / 1_200)
        voice.player.pan = pan
        voice.player.volume = gain
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !voice.player.isPlaying { voice.player.play() }
    }

    // MARK: - Output device

    /// Route audio to a specific output device (nil = system default).
    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        engine.stop()
        var id = deviceID ?? AudioDevices.defaultOutputDevice()
        if let unit = engine.outputNode.audioUnit, id != kAudioObjectUnknown {
            let err = AudioUnitSetProperty(unit,
                                           kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global,
                                           0,
                                           &id,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr {
                NSLog("OpenKlack: could not select output device \(id): \(err)")
            }
        }
        restart()
        // If the chosen device refuses to start, fall back to the default
        // device rather than staying silently dead.
        if !engine.isRunning, deviceID != nil {
            setOutputDevice(nil)
        }
    }
}
