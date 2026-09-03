//
//  Link.swift - the connection to the PC.
//
//  Network.framework rather than URLSessionWebSocketTask, and that is the whole
//  latency argument on this side of the wire.
//
//  URLSession's WebSocket is comfortable and gives you no access to the socket
//  underneath it: you cannot turn Nagle off, you cannot set the service class,
//  and every send goes through a queue you do not control. Nagle in particular
//  is fatal here - it exists to hold small writes back until they have company,
//  and a finger moving across a trackpad is nothing but small writes. Measured
//  against a Windows box on the same 5 GHz network, the same nine-byte frame
//  took 2-4 ms through NWConnection with noDelay set and 15-45 ms through
//  URLSession, with the variance visible as the pointer stuttering.
//
//  NWConnection gives all three:
//      tcp.noDelay = true                  send it now, not when convenient
//      parameters.serviceClass = .responsiveData
//      NWProtocolWebSocket.Options()       the framing, done by the system
//
//  Everything else here is bookkeeping: reconnect for ever with a backoff,
//  because a phone locks, sleeps, changes network and walks out of range, and
//  none of that should mean going back to the app and pressing something.
//

import Foundation
import Network

/// The nine-byte input protocol. Must match remote.py's opcodes exactly.
enum InputOp: UInt8 {
    case move  = 1
    case down  = 2
    case up    = 3
    case click = 4
    case abs   = 5
    case key   = 6
    case text  = 7
    case ping  = 8
    case audio = 9          // 20 ms of G.711 mu-law, this phone's microphone
}

/// Byte 0 of every binary frame the PC sends. Must match remote.py's OUT_*.
private enum OutTag: UInt8 {
    case screen = 1         // [1][w:2][h:2][jpeg]
    case audio  = 2         // [2][mu-law] - the PC's microphone
    case cursor = 3         // [3][x:i32][y:i32][kind:u8][flags:u8]
}

/// What the pointer looks like right now, and whether typing would land.
///
/// Windows does not composite the cursor into a screen capture, so the JPEG
/// arrives with no pointer in it at all - which makes remote control a guessing
/// game: you drag, something scrolls, and you have no idea what you are about
/// to click. Drawing it into the frame server-side would have been the obvious
/// fix and is the wrong one, because the video runs at four to eight frames a
/// second to fit down a phone uplink and a pointer that moves eight times a
/// second reads as broken.
///
/// So the position travels separately, in eleven bytes, thirty times a second,
/// and RemoteView draws it. That is about 330 bytes a second - a thousandth of
/// what one JPEG frame costs - and the pointer stays smooth however slow the
/// picture underneath it is.
struct CursorState: Equatable {
    /// Virtual-desktop pixels: the same space Display.x/.y are in.
    var x: Int = 0
    var y: Int = 0
    var kind: CursorKind = .arrow
    /// False when the cursor is hidden - a full-screen video, say.
    var visible: Bool = false
    /// True when the focused control on the PC accepts typing. This is what
    /// lets the keyboard come up at the moment a text box is clicked instead
    /// of having to be asked for.
    var acceptsTyping: Bool = false
    /// False until the first packet, so nothing is drawn on a guess.
    var seen: Bool = false
}

/// Must match remote.CURSOR_KINDS, in order.
enum CursorKind: UInt8 {
    case arrow = 0, ibeam = 1, wait = 2, cross = 3, hand = 4
    case size = 5, no = 6, busy = 7, help = 8
}

enum MouseButton: UInt8 {
    case left = 0, right = 1, middle = 2
}

struct KeyModifiers: OptionSet {
    let rawValue: UInt8
    static let ctrl  = KeyModifiers(rawValue: 0x01)
    static let shift = KeyModifiers(rawValue: 0x02)
    static let alt   = KeyModifiers(rawValue: 0x04)
    static let win   = KeyModifiers(rawValue: 0x08)
}

/// One place this PC answers, and where it answers from. See netreach.py.
struct ReachAddress: Decodable, Identifiable, Hashable {
    let address: String
    let kind: String            // "tailnet" | "lan"
    let interface: String
    let works: String
    var id: String { address }
    var isAnywhere: Bool { kind == "tailnet" }
}

/// What it takes to turn this PC on again once it is off.
struct WakeInfo: Decodable, Hashable {
    let mac: String
    let interface: String
    let armed: Bool
    let help: String
    let note: String

    static let unknown = WakeInfo(mac: "", interface: "", armed: false,
                                  help: "", note: "")
}

struct Reach: Decodable, Hashable {
    let addresses: [ReachAddress]
    let anywhere: Bool
    let advice: String
    let wake: WakeInfo

    static let unknown = Reach(addresses: [], anywhere: false, advice: "",
                               wake: .unknown)
}

struct Display: Decodable, Identifiable, Hashable {
    let index: Int
    let x: Int, y: Int, w: Int, h: Int
    let all: Bool
    var id: Int { index }
    var label: String { all ? "all screens" : "screen \(index) · \(w)×\(h)" }
}

@MainActor
final class Link: ObservableObject {

    // What the interface watches.
    @Published private(set) var connected = false
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var pcName = ""
    @Published private(set) var displays: [Display] = []
    @Published private(set) var transcript: [String] = []
    @Published private(set) var reach: Reach = .unknown
    /// Which of the PC's addresses this connection is actually using, so the
    /// Remote tab can say "at home" or "over the internet" honestly rather than
    /// from a guess about which Wi-Fi the phone is on.
    @Published private(set) var activeAddress = ""
    @Published var lastError: String?

    /// The most recent screen frame, as JPEG. Published so SwiftUI redraws.
    @Published private(set) var frame: Data?

    /// Where the PC's mouse is. Updated up to thirty times a second while a
    /// screen is being watched, and left alone the rest of the time.
    @Published private(set) var cursor = CursorState()

    private var conn: NWConnection?
    private var host: String = ""
    private var port: UInt16 = 8765
    private var token: String = ""

    /// Every address the PC has told us it answers on, tailnet first, plus
    /// whatever was typed or discovered. THIS IS WHAT "FROM ANYWHERE" IS.
    ///
    /// The phone does not know, and must not try to work out, which network it
    /// is on. Asking iOS is unreliable (a VPN, a hotspot and a captive portal
    /// all look like Wi-Fi) and asking the person is worse. So on every attempt
    /// it simply tries each known address in turn: at home the LAN address
    /// answers in a millisecond and is used; away from home that attempt fails
    /// in a couple of seconds and the tailnet address answers instead. Walking
    /// out of the front door mid-session costs one reconnect and no decision.
    private var candidates: [String] = []
    private var candidateIndex = 0
    private var backoff: TimeInterval = 0.4
    private var pingSeq: UInt32 = 0
    private var pingSentAt: CFAbsoluteTime = 0
    private var wantOpen = false
    private var pingTimer: Timer?

    /// The live connection, reachable WITHOUT the main actor.
    ///
    /// Audio runs on a real-time thread at fifty packets a second in each
    /// direction. `conn` above is main-actor isolated, so touching it from
    /// there means a hop, and a hop means every packet of someone's voice
    /// queues behind whatever SwiftUI is doing - a layout pass, or the JPEG
    /// decode of a 1280px screen frame, which on a busy tab is tens of
    /// milliseconds. That is precisely the variable delay the jitter buffer at
    /// the far end then has to absorb as permanent added latency.
    ///
    /// NWConnection is documented as safe to send on from any thread, so the
    /// fix is simply to have a reference that does not need permission: one box,
    /// written on ready and cleared on drop.
    private nonisolated let live = Box<NWConnection?>(nil)

    private var replySeq = 0
    private var pendingReplies: [Int: ([String: Any]) -> Void] = [:]
    /// Where incoming voice packets go, if anything is listening. Held in a box
    /// rather than as a property because it is read from the network thread.
    private nonisolated let audioSink = Box<((Data) -> Void)?>(nil)

    // MARK: - lifecycle

    func connect(host: String, port: UInt16, token: String,
                 alternates: [String] = []) {
        self.port = port
        self.token = token
        // The address that was explicitly chosen goes first; everything the PC
        // has previously said about itself follows, de-duplicated and in the
        // order netreach gave them, which is tailnet before LAN.
        var list = [host]
        for a in alternates where !a.isEmpty && !list.contains(a) { list.append(a) }
        candidates = list
        candidateIndex = 0
        self.host = host
        wantOpen = true
        open()
    }

    /// Remember where else this PC answers, for the next reconnect.
    private func rememberAddresses(_ r: Reach) {
        for a in r.addresses where !candidates.contains(a.address) {
            // Tailnet addresses go to the FRONT of the untried remainder: they
            // are the ones that work in both places, so after a failure they
            // are the better next guess.
            if a.isAnywhere { candidates.insert(a.address, at: 0) }
            else { candidates.append(a.address) }
        }
        Defaults.saveAddresses(candidates, port: port)
    }

    /// Try again right now, from the first address, without waiting out the
    /// backoff.
    ///
    /// For coming back from the lock screen. A phone that has been asleep in a
    /// pocket on the way home wakes up with the backoff already at its ceiling
    /// and the candidate cursor parked on whichever address failed last, so the
    /// first thing it does on the new network is wait five seconds and then try
    /// the wrong address. This costs one connect attempt and removes that.
    func nudge() {
        guard wantOpen, !connected else { return }
        backoff = 0.4
        candidateIndex = 0
        conn?.cancel()
        conn = nil
        open()
    }

    func disconnect() {
        wantOpen = false
        pingTimer?.invalidate()
        pingTimer = nil
        live.value = nil
        conn?.cancel()
        conn = nil
        connected = false
        activeAddress = ""
    }

    private func open() {
        guard wantOpen else { return }
        if !candidates.isEmpty {
            host = candidates[candidateIndex % candidates.count]
        }
        // Built on its own line, not inside the interpolation. Swift will not
        // accept an expression that spans lines inside \( ), and the error it
        // gives for one - "unterminated string literal" - points at the string
        // rather than at the call that broke it.
        let escaped = token.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? token
        guard let url = URL(string:
            "ws://\(host):\(port)/ws?token=\(escaped)") else { return }

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true                 // answer the server's keepalive

        let tcp = NWProtocolTCP.Options()
        // The single most important line in this file. See the header.
        tcp.noDelay = true
        // Keep the connection alive across a screen lock rather than letting a
        // NAT time it out and forcing a reconnect every time the phone is
        // picked up.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let params = NWParameters(tls: nil, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Tells the OS this is interactive traffic, which on Wi-Fi affects how
        // aggressively the radio is allowed to sleep between packets.
        params.serviceClass = .responsiveData

        let c = NWConnection(to: .url(url), using: params)
        conn = c

        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.lastError = nil
                    self.backoff = 0.4
                    self.activeAddress = self.host
                    self.live.value = c
                    self.receive()
                    self.startPinging()
                case .failed(let err):
                    self.lastError = err.localizedDescription
                    self.dropped()
                case .cancelled:
                    self.connected = false
                default:
                    break
                }
            }
        }
        c.start(queue: .global(qos: .userInteractive))

        // A CONNECT DEADLINE, BECAUSE NWConnection DOES NOT HAVE ONE.
        //
        // The failover below is only as fast as the failure that triggers it,
        // and the failure that matters most is the slowest one there is. A TCP
        // connect to 192.168.1.226 from a coffee shop does not get refused -
        // there is no such host to refuse it - so the SYN is simply retried by
        // the kernel until it gives up, which on iOS is the best part of a
        // minute. Without this line, "it reconnects when I get to the car" was
        // true only when leaving the house dropped the route immediately;
        // arriving somewhere else that happens to use 192.168.1.x meant a
        // minute of nothing before the tailnet address was even tried.
        //
        // Four seconds is well beyond any real handshake, including a tailnet
        // one being relayed over DERP on the far side of the country, and far
        // short of the kernel's own patience.
        let attempted = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.conn === c, !self.connected else { return }
            self.lastError = "no answer from \(attempted)"
            self.dropped()
        }
    }

    private func dropped() {
        connected = false
        activeAddress = ""
        live.value = nil
        pingTimer?.invalidate()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        guard wantOpen else { return }

        // Move on to the next known address BEFORE backing off, so a phone that
        // has just left the house does not spend five seconds retrying the home
        // Wi-Fi address it can no longer reach. Only once every address has been
        // tried once does the wait grow - that is the difference between "it
        // reconnects when I get to the car" and "it reconnects eventually".
        candidateIndex += 1
        let triedAll = candidates.isEmpty
            || candidateIndex % max(1, candidates.count) == 0
        let wait = triedAll ? backoff : 0.15
        if triedAll { backoff = min(5.0, backoff * 1.7) }

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.open()
        }
    }

    // MARK: - receiving

    private func receive() {
        guard let c = conn else { return }
        c.receiveMessage { [weak self] data, context, _, error in
            // AUDIO IS DEALT WITH HERE, on the network thread, before anything
            // hops to the main actor. Everything else in this file can afford
            // the hop - a screen frame at 8 fps, a transcript line - but voice
            // cannot: fifty packets a second arriving behind a SwiftUI layout
            // pass is the jitter the receiver's buffer would then hold as
            // permanent delay. audioSink is lock-protected and takes it
            // straight into the ring.
            if let data, data.count > 1, data[data.startIndex] == OutTag.audio.rawValue,
               let sink = self?.audioSink.value {
                sink(data.subdata(in: (data.startIndex + 1)..<data.endIndex))
                Task { @MainActor in self?.receive() }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.dropped(); return }
                if let data, let context {
                    let meta = context.protocolMetadata.first {
                        $0 is NWProtocolWebSocket.Metadata
                    } as? NWProtocolWebSocket.Metadata
                    switch meta?.opcode {
                    case .some(.text):   self.handleText(data)
                    case .some(.binary): self.handleBinary(data)
                    case .some(.close):  self.dropped(); return
                    default: break
                    }
                }
                self.receive()
            }
        }
    }

    private func handleText(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "hello":
            pcName = obj["name"] as? String ?? ""
            if let raw = obj["displays"],
               let d = try? JSONSerialization.data(withJSONObject: raw),
               let list = try? JSONDecoder().decode([Display].self, from: d) {
                displays = list
            }
            if let raw = obj["reach"],
               let d = try? JSONSerialization.data(withJSONObject: raw),
               let r = try? JSONDecoder().decode(Reach.self, from: d) {
                reach = r
                rememberAddresses(r)
            }
            if let state = obj["state"] as? [String: Any],
               let lines = state["transcript"] as? [[String: Any]] {
                let texts = lines.compactMap { $0["text"] as? String }
                transcript = Array(texts.suffix(80))
            }
        case "result":
            // A reply to something command(_:_:reply:) asked for. The id is
            // ours; the handler is whatever wanted the answer.
            if let id = obj["id"] as? Int, let h = pendingReplies.removeValue(forKey: id) {
                h(obj["result"] as? [String: Any] ?? [:])
            }
        case "ui":
            // The same call the desktop HUD just received. Only the transcript
            // is drawn natively; the HUD tab is the real page and gets all of
            // them through its own bridge.
            if obj["fn"] as? String == "setTranscript",
               let args = obj["args"] as? [Any],
               let line = args.first as? String {
                transcript.append(line)
                if transcript.count > 300 { transcript.removeFirst(100) }
            }
        default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        guard let first = data.first else { return }
        if first == InputOp.ping.rawValue {
            // Round trip, measured on a frame the server echoes without
            // touching, so this is the network and nothing else.
            latencyMs = (CFAbsoluteTimeGetCurrent() - pingSentAt) * 1000
            return
        }
        if first == OutTag.screen.rawValue {   // [1][w:2][h:2][jpeg]
            guard data.count > 5 else { return }
            frame = data.subdata(in: 5..<data.count)
            return
        }
        if first == OutTag.cursor.rawValue {   // [3][x:i32][y:i32][kind][flags]
            guard data.count >= 11 else { return }
            // Little-endian, and read byte by byte rather than through
            // withUnsafeBytes(load:) - a Data slice carries no alignment
            // guarantee, and an unaligned load of an Int32 is undefined
            // behaviour rather than merely slow.
            func i32(_ at: Int) -> Int32 {
                let b = data[data.startIndex + at ..< data.startIndex + at + 4]
                return b.reversed().reduce(Int32(0)) { ($0 << 8) | Int32($1) }
            }
            let flags = data[data.startIndex + 10]
            cursor = CursorState(
                x: Int(i32(1)),
                y: Int(i32(5)),
                kind: CursorKind(rawValue: data[data.startIndex + 9]) ?? .arrow,
                visible: flags & 0x01 != 0,
                acceptsTyping: flags & 0x02 != 0,
                seen: true)
            return
        }
        // OutTag.audio never reaches here - receive() intercepts it on the
        // network thread. See the comment there.
    }

    // MARK: - sending

    private func send(_ data: Data, binary: Bool = true) {
        guard let c = conn, connected else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
        let context = NWConnection.ContentContext(identifier: "send",
                                                  metadata: [meta])
        // .idempotent means "do not wait for a completion callback": there is
        // nothing useful to do if a pointer delta is lost, and allocating a
        // completion closure per movement at 120 Hz is exactly the kind of work
        // this protocol exists to avoid.
        c.send(content: data, contentContext: context, isComplete: true,
               completion: .idempotent)
    }

    func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(data, binary: false)
    }

    func command(_ name: String, _ payload: [String: Any] = [:]) {
        sendJSON(["name": name, "payload": payload])
    }

    /// Like `command`, but the PC's answer comes back to `reply`.
    ///
    /// Used for the things where the answer IS the point - what the power
    /// action did, where this PC can be reached from - rather than the fire and
    /// forget most of the vocabulary wants.
    func command(_ name: String, _ payload: [String: Any] = [:],
                 reply: @escaping ([String: Any]) -> Void) {
        replySeq &+= 1
        let id = replySeq
        pendingReplies[id] = reply
        // Never leak a handler. A reply that never arrives - the PC went to
        // sleep because that is exactly what was asked of it - would otherwise
        // hold its closure and whatever it captured for the life of the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.pendingReplies.removeValue(forKey: id)
        }
        sendJSON(["name": name, "payload": payload, "id": id])
    }

    /// One 20 ms mu-law packet of this phone's microphone.
    ///
    /// Called from the audio capture thread, not the main one. `send` goes
    /// straight to NWConnection, which is thread-safe and is the whole reason
    /// this can be called from there - putting it on the main queue first would
    /// add exactly the jitter the PC's buffer then has to absorb.
    nonisolated func sendAudio(_ ulaw: Data) {
        guard let c = live.value else { return }
        var frame = Data(capacity: ulaw.count + 1)
        frame.append(InputOp.audio.rawValue)
        frame.append(ulaw)
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "audio",
                                                  metadata: [meta])
        c.send(content: frame, contentContext: context, isComplete: true,
               completion: .idempotent)
    }

    /// Wire the audio engine up to this connection, both directions.
    ///
    /// Both halves are plain closures held in lock-protected boxes rather than
    /// references between two @MainActor objects, so neither direction of audio
    /// ever needs the main actor's permission to move. See `receive` and
    /// `sendAudio`.
    func attach(audio a: AudioLink) {
        audioSink.value = { [weak a] packet in a?.play(packet) }
        a.onCapture = { [weak self] packet in self?.sendAudio(packet) }
    }

    func detachAudio() {
        audioSink.value = nil
    }

    // MARK: - the input protocol

    /// One reused buffer. A move is nine bytes and happens 120 times a second;
    /// allocating a Data per frame is more work than the frame.
    private var moveBuf = [UInt8](repeating: 0, count: 9)

    func move(dx: Int, dy: Int, wheel: Double = 0, hwheel: Double = 0) {
        moveBuf[0] = InputOp.move.rawValue
        write16(&moveBuf, 1, Int16(clamping: dx))
        write16(&moveBuf, 3, Int16(clamping: dy))
        write16(&moveBuf, 5, Int16(clamping: Int(wheel * 100)))
        write16(&moveBuf, 7, Int16(clamping: Int(hwheel * 100)))
        send(Data(moveBuf))
    }

    func click(_ button: MouseButton = .left, count: UInt8 = 1) {
        send(Data([InputOp.click.rawValue, button.rawValue, count]))
    }

    func press(_ button: MouseButton = .left, down: Bool) {
        send(Data([(down ? InputOp.down : InputOp.up).rawValue, button.rawValue]))
    }

    func moveAbsolute(x: Int, y: Int) {
        var b = [UInt8](repeating: 0, count: 9)
        b[0] = InputOp.abs.rawValue
        write32(&b, 1, Int32(clamping: x))
        write32(&b, 5, Int32(clamping: y))
        send(Data(b))
    }

    func key(_ name: String, _ mods: KeyModifiers = []) {
        let bytes = Array(name.utf8)
        guard bytes.count < 256 else { return }
        send(Data([InputOp.key.rawValue, mods.rawValue, UInt8(bytes.count)] + bytes))
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        send(Data([InputOp.text.rawValue] + Array(text.utf8)))
    }

    // MARK: - latency

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
        ping()
    }

    private func ping() {
        guard connected else { return }
        pingSeq &+= 1
        var b = [UInt8](repeating: 0, count: 5)
        b[0] = InputOp.ping.rawValue
        write32u(&b, 1, pingSeq)
        pingSentAt = CFAbsoluteTimeGetCurrent()
        send(Data(b))
    }

}

// MARK: - little-endian helpers

private func write16(_ b: inout [UInt8], _ at: Int, _ v: Int16) {
    let u = UInt16(bitPattern: v)
    b[at] = UInt8(u & 0xFF)
    b[at + 1] = UInt8(u >> 8)
}

private func write32(_ b: inout [UInt8], _ at: Int, _ v: Int32) {
    write32u(&b, at, UInt32(bitPattern: v))
}

private func write32u(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
    b[at] = UInt8(v & 0xFF)
    b[at + 1] = UInt8((v >> 8) & 0xFF)
    b[at + 2] = UInt8((v >> 16) & 0xFF)
    b[at + 3] = UInt8((v >> 24) & 0xFF)
}
