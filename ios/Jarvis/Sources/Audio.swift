//
//  Audio.swift - hearing the room, and talking into it.
//
//      "and i can hear mic and talk through"
//
//  LISTEN   the PC's microphone arrives as G.711 mu-law at 16 kHz and is played
//           out of this phone.
//  TALK     this phone's microphone goes the other way and comes out of the
//           PC's speakers.
//
//  Both halves are 20 ms packets of 16 kHz mono mu-law - 320 bytes, 128 kbps -
//  which is the format remoteaudio.py fixed on and the reasoning for it is in
//  that file's header. The short version: Opus is four times better and needs a
//  native library on both ends; mu-law is a 256-entry table, it is in Python's
//  standard library and it is forty lines here, and 58 MB an hour of
//  intermittent talkback is not what runs a data plan out.
//
//  ---------------------------------------------------------------------------
//  THE THREE THINGS THAT ARE EASY TO GET WRONG ON iOS
//
//  1. THE HARDWARE SAMPLE RATE IS NOT 16 kHz AND YOU DO NOT GET TO CHOOSE IT.
//     AVAudioSession will give you 48 kHz, or 44.1, or 24 on a call, and it can
//     CHANGE mid-session when AirPods connect. So the tap's format is read from
//     the input node at the moment the tap is installed - never assumed - and
//     an AVAudioConverter does the resampling. Hard-coding 16000 here produces
//     audio that is the right length and the wrong pitch, which sounds like a
//     bug in the network rather than in the format.
//
//  2. .playAndRecord ROUTES TO THE EARPIECE BY DEFAULT. Not the speaker - the
//     earpiece, the one you hold against your head. Someone pressing "listen to
//     my PC" and getting near-silence unless they hold the phone to their face
//     is the single most common report about apps that do this.
//     .defaultToSpeaker is what fixes it, and it has to be an option on the
//     category rather than an override applied afterwards, or it is lost every
//     time the route changes.
//
//  3. THE RENDER BLOCK IS REAL TIME. AVAudioSourceNode's block runs on a thread
//     with a deadline of a few milliseconds and no allocator worth using. It
//     may not lock against a thread that can be preempted, it may not allocate,
//     and it may not call anything in Foundation that might. So the jitter
//     buffer underneath it is a plain ring of Int16 with an os_unfair_lock -
//     which does not sleep - and the render block does nothing but copy out of
//     it and convert to Float.
//

import AVFoundation
import Foundation
import os

// MARK: - G.711 mu-law

/// The codec, as two 256/65536-entry tables built once.
///
/// Table-driven rather than arithmetic because it has to agree with Python's
/// `audioop` EXACTLY, and audioop is Sun's 14-bit variant rather than the 16-bit
/// one most references print: it shifts the sample down two bits first, biases
/// by 33 rather than 132, and takes the mantissa at (segment + 1). A textbook
/// encoder is a perfectly good mu-law encoder and disagrees with it on most
/// inputs, which would be a faint permanent distortion nobody could attribute
/// to anything. remoteaudio.py's fallback carries the same tables and a test
/// that checks all 65,536 samples against audioop.
enum ULaw {

    private static let segmentEnd: [Int32] = [0x3F, 0x7F, 0xFF, 0x1FF,
                                              0x3FF, 0x7FF, 0xFFF, 0x1FFF]
    private static let clip: Int32 = 8159
    private static let bias: Int32 = 33          // 0x84 >> 2

    /// 256 mu-law codes to their Int16 samples.
    static let decodeTable: [Int16] = {
        var t = [Int16](repeating: 0, count: 256)
        for u in 0..<256 {
            let v = ~u & 0xFF
            var s = Int32(((v & 0x0F) << 3) + 0x84)
            s <<= Int32((v & 0x70) >> 4)
            t[u] = Int16(truncatingIfNeeded: (v & 0x80) != 0 ? (0x84 - s) : (s - 0x84))
        }
        return t
    }()

    static func encode(_ sample: Int16) -> UInt8 {
        var p = Int32(sample) >> 2               // arithmetic shift, floors
        let mask: Int32
        if p < 0 { p = -p; mask = 0x7F } else { mask = 0xFF }
        if p > clip { p = clip }
        p += bias
        var seg = 8
        for (i, end) in segmentEnd.enumerated() where p <= end { seg = i; break }
        if seg >= 8 { return UInt8(truncatingIfNeeded: 0x7F ^ mask) }
        let uval = Int32(seg << 4) | ((p >> Int32(seg + 1)) & 0x0F)
        return UInt8(truncatingIfNeeded: uval ^ mask)
    }

    static func encode(_ samples: UnsafePointer<Int16>, count: Int) -> Data {
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return }
            for i in 0..<count { p[i] = encode(samples[i]) }
        }
        return out
    }

    static func decode(_ data: Data) -> [Int16] {
        var out = [Int16](repeating: 0, count: data.count)
        let table = decodeTable
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return }
            for i in 0..<data.count { out[i] = table[Int(p[i])] }
        }
        return out
    }
}

// MARK: - the jitter buffer

/// A fixed ring of Int16 samples, safe to read from a render thread.
///
/// Fixed rather than growing, and `os_unfair_lock` rather than a queue or an
/// actor, because the reader is AVAudioSourceNode's render block. That block has
/// a hard deadline; anything that can put it to sleep - a mutex that can be held
/// by a preempted thread, an allocation, a hop to an actor - shows up as a click
/// on every glitch and eventually as the engine dropping the node.
private final class JitterBuffer: @unchecked Sendable {

    /// 2 seconds at 16 kHz. Far more than TARGET or MAX; it is a ring, and the
    /// policy about how full to keep it lives in `push`.
    private var ring = [Int16](repeating: 0, count: 32000)
    private var head = 0                 // next write
    private var tail = 0                 // next read
    private var count = 0

    /// Allocated, not a stored `var`.
    ///
    /// `os_unfair_lock_lock(&someStoredProperty)` compiles and is wrong: Swift
    /// makes no promise that the inout address of a property is the same
    /// address twice, and a lock at a moving address is not a lock. The
    /// documented pattern is a pointer that is allocated once and never moves.
    private let lock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let p = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock_s())
        return p
    }()

    deinit { lock.deallocate() }

    let targetSamples: Int
    let maxSamples: Int

    private(set) var priming = true
    private(set) var underruns = 0
    private(set) var dropped = 0

    init(rate: Int, targetMs: Int, maxMs: Int) {
        targetSamples = rate * targetMs / 1000
        maxSamples = rate * maxMs / 1000
    }

    var buffered: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    func push(_ samples: [Int16]) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for s in samples {
            ring[head] = s
            head = (head + 1) % ring.count
            if count == ring.count { tail = (tail + 1) % ring.count } else { count += 1 }
        }
        // A backlog means the connection stalled and then delivered everything
        // at once. Playing it out makes every word from then on late by the
        // length of the stall, permanently - it never catches up on its own.
        // Dropping back to the target costs only the stall itself.
        if count > maxSamples {
            let drop = count - targetSamples
            tail = (tail + drop) % ring.count
            count -= drop
            dropped += drop
        }
        if priming && count >= targetSamples { priming = false }
    }

    /// Fills `out` with whatever is available and silence for the rest.
    /// Returns false if it underran, so the caller can re-prime.
    func pull(into out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        if priming {
            for i in 0..<frames { out[i] = 0 }
            return true
        }
        var i = 0
        while i < frames && count > 0 {
            out[i] = Float(ring[tail]) / 32768.0
            tail = (tail + 1) % ring.count
            count -= 1
            i += 1
        }
        if i < frames {
            // Silence, never a repeat of the last block. A repeat is an audible
            // buzz and it is worse than the gap it is hiding.
            while i < frames { out[i] = 0; i += 1 }
            underruns += 1
            if count == 0 { priming = true }
            return false
        }
        return true
    }

    func reset() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        head = 0; tail = 0; count = 0; priming = true
    }
}

// MARK: - small cross-thread holders

/// A lock-protected box, so a @MainActor object can expose one mutable value to
/// a real-time thread without either of them awaiting the other.
final class Box<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Turns a stream of arbitrary-length Int16 runs into exact fixed-size mu-law
/// packets, keeping whatever does not fill one.
final class Packetiser: @unchecked Sendable {
    private var pending: [Int16] = []
    private let lock = NSLock()
    private let frame: Int

    init(frame: Int) { self.frame = frame }

    func add(_ samples: UnsafePointer<Int16>, count: Int) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        var out: [Data] = []
        while pending.count >= frame {
            let chunk = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            out.append(chunk.withUnsafeBufferPointer {
                ULaw.encode($0.baseAddress!, count: $0.count)
            })
        }
        return out
    }

    func reset() {
        lock.lock(); pending.removeAll(keepingCapacity: true); lock.unlock()
    }
}

// MARK: - the engine

@MainActor
final class AudioLink: ObservableObject {

    static let rate: Double = 16000
    static let frameSamples = 320                 // 20 ms

    @Published private(set) var listening = false     // PC mic -> this phone
    @Published private(set) var talking = false       // this phone -> PC
    @Published var lastError: String?

    /// Set by whoever owns the link. Called with one 20 ms mu-law packet, on
    /// the capture thread rather than the main one - see handleCaptured. The
    /// only thing it is ever set to is Link.sendAudio, which is a socket write.
    var onCapture: ((Data) -> Void)? {
        get { captureSink.value }
        set { captureSink.value = newValue }
    }

    private let engine = AVAudioEngine()
    private nonisolated let buffer = JitterBuffer(rate: Int(AudioLink.rate),
                                                  targetMs: 120, maxMs: 600)
    private var source: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var sessionConfigured = false

    /// The leftover-sample buffer, and the closure the packets go to. Both live
    /// outside the actor because the capture thread writes them; see
    /// handleCaptured.
    private nonisolated let packetiser = Packetiser(frame: AudioLink.frameSamples)
    private nonisolated let captureSink = Box<((Data) -> Void)?>(nil)

    // MARK: session

    private func configureSession(record: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        // .playAndRecord for both directions even when only listening, because
        // switching category mid-session tears the engine down and the first
        // half second of talkback is lost every time the button is pressed.
        // .defaultToSpeaker is the line that stops "listen" playing out of the
        // earpiece - see the header.
        try s.setCategory(.playAndRecord,
                          mode: .voiceChat,
                          options: [.defaultToSpeaker, .allowBluetooth,
                                    .allowBluetoothA2DP])
        // A REQUEST, not a setting. iOS honours it when it can and quietly does
        // something else when it cannot, which is why nothing downstream is
        // allowed to assume the result - the tap reads the format it actually
        // got. Asking still helps: when it is granted there is no resampling to
        // do at all.
        try? s.setPreferredSampleRate(AudioLink.rate)
        try? s.setPreferredIOBufferDuration(0.02)
        try s.setActive(true)
        sessionConfigured = true
    }

    private func ensureEngine() throws {
        if source != nil { return }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioLink.rate,
                                      channels: 1, interleaved: false)
        else { throw NSError(domain: "jarvis.audio", code: 1) }

        let node = AVAudioSourceNode(format: fmt) { [buffer] _, _, frameCount, abl in
            // REAL TIME. No allocation, no locking that can sleep, no Swift
            // runtime beyond what is inlined here. See the header.
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            _ = buffer.pull(into: out, frames: Int(frameCount))
            // Mono into however many buffers the graph asked for.
            for i in 1..<list.count {
                if let extra = list[i].mData?.assumingMemoryBound(to: Float.self) {
                    memcpy(extra, out, Int(frameCount) * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        source = node
    }

    // MARK: - LISTEN: play what the PC's microphone hears

    func startListening() {
        do {
            try configureSession(record: true)
            try ensureEngine()
            buffer.reset()
            if !engine.isRunning { try engine.start() }
            listening = true
            lastError = nil
        } catch {
            lastError = "Could not start audio: \(error.localizedDescription)"
            listening = false
        }
    }

    func stopListening() {
        listening = false
        buffer.reset()
        idleStopIfPossible()
    }

    /// One mu-law packet from the PC. Called straight off the network thread.
    ///
    /// It does NOT hop to the main actor to get there. The jitter buffer is
    /// lock-protected precisely so that it does not have to: a hop would put
    /// every packet behind whatever the interface is doing - a SwiftUI layout
    /// pass, a JPEG decode of a screen frame - which is exactly the variable
    /// delay the buffer exists to absorb. Feeding a jitter buffer through a
    /// jittery queue is the one thing that cannot be allowed.
    nonisolated func play(_ ulaw: Data) {
        buffer.push(ULaw.decode(ulaw))
    }

    // MARK: - TALK: send this phone's microphone to the PC

    func startTalking() {
        // AVAudioApplication, not AVAudioSession.requestRecordPermission - the
        // latter is deprecated as of iOS 17 and this project's floor IS 17
        // (project.yml). Deprecated is only a warning today; it is also the
        // call that gets removed.
        AVAudioApplication.requestRecordPermission { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                guard ok else {
                    self.lastError = "Microphone access is off for Jarvis. "
                        + "Settings › Jarvis › Microphone."
                    return
                }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        do {
            try configureSession(record: true)
            try ensureEngine()

            let input = engine.inputNode
            // READ, never assumed. The hardware decides this and it changes
            // when a headset connects - see the header.
            let hwFormat = input.inputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0 else {
                lastError = "No microphone input is available."
                return
            }
            guard let wire = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: AudioLink.rate,
                                           channels: 1, interleaved: true),
                  let conv = AVAudioConverter(from: hwFormat, to: wire)
            else {
                lastError = "This device's microphone format is unsupported."
                return
            }
            converter = conv
            packetiser.reset()

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) {
                [weak self] buf, _ in
                self?.handleCaptured(buf, using: conv, to: wire)
            }

            if !engine.isRunning { try engine.start() }
            talking = true
            lastError = nil
        } catch {
            lastError = "Could not open the microphone: \(error.localizedDescription)"
            talking = false
        }
    }

    func stopTalking() {
        talking = false
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        packetiser.reset()
        idleStopIfPossible()
    }

    /// Resample, chop into exact 20 ms packets, encode, hand over.
    private nonisolated func handleCaptured(_ buf: AVAudioPCMBuffer,
                                            using conv: AVAudioConverter,
                                            to wire: AVAudioFormat) {
        // Runs on the audio tap's own thread and STAYS there. An earlier pass
        // hopped to the main actor to append to the leftover buffer, which put
        // every 20 ms of the user's voice behind whatever SwiftUI happened to
        // be doing - a layout pass, a JPEG decode of a screen frame - and the
        // result was a talkback stream that was mostly on time and
        // occasionally 200 ms late. The PC's jitter buffer would then either
        // absorb that as permanent added delay or drop it. Capture is a
        // real-time producer; it gets a lock, not a queue.

        // Capacity for the worst case: converting 48 kHz down to 16 cannot grow
        // the frame count, but a device running at 8 kHz would, so this is
        // sized from the ratio rather than assumed to shrink.
        let ratio = wire.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity)
        else { return }

        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        if err != nil { return }
        guard out.frameLength > 0,
              let src = out.int16ChannelData?[0] else { return }

        // Exact 20 ms packets. The PC's jitter buffer is sized in packets and a
        // stream of ragged ones - 47 samples, then 900 - defeats it: it holds
        // "120 ms of audio" arriving in lumps the wrong shape, which is the
        // same as not holding any.
        let packets = packetiser.add(src, count: Int(out.frameLength))
        guard !packets.isEmpty, let sink = captureSink.value else { return }
        for p in packets { sink(p) }
    }

    // MARK: - teardown

    private func idleStopIfPossible() {
        guard !listening && !talking else { return }
        engine.stop()
        if sessionConfigured {
            // Handing the session back matters: while it is active and
            // .playAndRecord, iOS shows the orange microphone dot and other
            // apps' audio is ducked. Leaving it on after the button is
            // released is how an app gets a reputation for listening.
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            sessionConfigured = false
        }
    }

    var stats: String {
        let ms = buffer.buffered * 1000 / Int(AudioLink.rate)
        return "\(ms) ms buffered"
    }
}
