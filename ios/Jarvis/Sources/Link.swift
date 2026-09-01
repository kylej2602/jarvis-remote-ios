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
    @Published var lastError: String?

    /// The most recent screen frame, as JPEG. Published so SwiftUI redraws.
    @Published private(set) var frame: Data?

    private var conn: NWConnection?
    private var host: String = ""
    private var port: UInt16 = 8765
    private var token: String = ""
    private var backoff: TimeInterval = 0.4
    private var pingSeq: UInt32 = 0
    private var pingSentAt: CFAbsoluteTime = 0
    private var wantOpen = false
    private var pingTimer: Timer?

    // MARK: - lifecycle

    func connect(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
        wantOpen = true
        open()
    }

    func disconnect() {
        wantOpen = false
        pingTimer?.invalidate()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        connected = false
    }

    private func open() {
        guard wantOpen, let url = URL(string:
            "ws://\(host):\(port)/ws?token=\(token.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? token)") else { return }

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
    }

    private func dropped() {
        connected = false
        pingTimer?.invalidate()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        guard wantOpen else { return }
        let wait = backoff
        backoff = min(5.0, backoff * 1.7)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.open()
        }
    }

    // MARK: - receiving

    private func receive() {
        guard let c = conn else { return }
        c.receiveMessage { [weak self] data, context, _, error in
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
            if let state = obj["state"] as? [String: Any],
               let lines = state["transcript"] as? [[String: Any]] {
                let texts = lines.compactMap { $0["text"] as? String }
                transcript = Array(texts.suffix(80))
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
        if first == 1 {                       // a screen frame: [1][w:2][h:2][jpeg]
            guard data.count > 5 else { return }
            frame = data.subdata(in: 5..<data.count)
        }
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
