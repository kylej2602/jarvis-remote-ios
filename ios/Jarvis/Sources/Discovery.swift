//
//  Discovery.swift - finding the PC without typing an IP address.
//
//  WHY THIS SWEEPS THE SUBNET RATHER THAN BROADCASTING, WHICH IS WHAT THE PC
//  SIDE IS SET UP FOR AND WOULD BE THE OBVIOUS ANSWER.
//
//  remote.py answers a UDP broadcast on port 48999, and any other client can
//  use it. An iOS app cannot, without an entitlement: since iOS 14, sending to
//  a broadcast or multicast address requires
//  com.apple.developer.networking.multicast, which Apple grants only by written
//  request per application. A sideloaded build signed with a personal
//  development certificate cannot have it at all. An app that shipped with the
//  broadcast path as its discovery would therefore find nothing, for a reason
//  no user could ever work out.
//
//  So this asks every address on the phone's own /24 whether it is a Jarvis, in
//  parallel, with a short timeout. Two hundred and fifty three plain HTTP GETs
//  against /api/hello, forty at a time, finishes in about a second and a half
//  on a home network and needs nothing but the Local Network permission - which
//  the app has to ask for regardless, because it cannot connect without it.
//
//  AND THAT SWEEP IS NOT TRIED FIRST, BECAUSE IT ONLY EVER WORKS AT HOME.
//
//  A subnet sweep is a question about the network the phone happens to be on.
//  On mobile data there is no subnet to sweep at all - subnetPrefix() returns
//  nil for pdp_ip0 deliberately - and on somebody else's Wi-Fi the sweep finds
//  their printer. So the first thing tried is the set of addresses that are
//  true wherever the phone is: the PC's tailnet name, and every address it has
//  previously reported. Those are asked in parallel with a longer timeout,
//  before a single LAN address is touched.
//
//  The tailnet name is `jarvis`, and it is not a guess. The machine is named
//  that on the tailnet on purpose (`tailscale set --hostname=jarvis`), so that
//  MagicDNS gives it a name this app can know at build time without anything
//  personal being written into a public repository - `jarvis` resolves to a
//  100.x address only for devices signed into the same tailnet, and to nothing
//  at all for anybody else. That single line is what makes a fresh install
//  connect from a train, having never once been on the home Wi-Fi.
//
//  /api/hello is deliberately unauthenticated and deliberately says almost
//  nothing: that a Jarvis is here, what the machine is called, and whether it
//  has ever been paired with anything. Enough to put a name in a list, and
//  nothing that is any use to whoever else is on the coffee shop Wi-Fi.
//
//  Pairing lives here too, because it is the other half of "find my PC": the
//  six-digit code Jarvis reads out is exchanged for the long-lived key, which
//  goes into the Keychain rather than UserDefaults. UserDefaults is a plist in
//  the app container and is copied into unencrypted backups; this key can move
//  the pointer and type on somebody's computer.
//

import Darwin
import Foundation
import Network
import Security
import UIKit

struct FoundPC: Identifiable, Hashable {
    let name: String
    let address: String
    let port: UInt16
    let paired: Bool
    /// Every OTHER address this same PC answers on, straight from /api/hello.
    /// Carried through pairing into Link.candidates, which is what makes the
    /// connection survive a change of network without being told anything.
    var alternates: [String] = []
    var id: String { "\(address):\(port)" }
}

/// What /api/hello says. A struct rather than a tuple because it grew a third
/// member - the address list - and `if let (a, b, c) = ...` at three call sites
/// is where a mix-up hides.
struct Hello {
    let name: String
    let paired: Bool
    /// Tailnet addresses first; netreach.py orders them that way on the PC.
    let addresses: [String]
}

@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var found: [FoundPC] = []
    @Published private(set) var searching = false
    @Published private(set) var progress: Double = 0
    @Published var error: String?

    private let port: UInt16
    private var task: Task<Void, Never>?

    init(port: UInt16 = 8765) {
        self.port = port
    }

    /// Names that reach the PC from ANYWHERE, asked before the subnet sweep.
    ///
    /// `jarvis` is the machine's name on the tailnet, set on the PC with
    /// `tailscale set --hostname=jarvis`. MagicDNS publishes it to every device
    /// signed into the same tailnet and to nobody else, and Tailscale installs
    /// the tailnet's suffix as a DNS search domain, so the bare short name
    /// resolves on the phone whether it is on the home Wi-Fi, on a hotel
    /// network or on 5G. Being a NAME rather than an address is the point:
    /// nothing personal is hard-coded into a public repository, and it keeps
    /// working if the 100.x address is ever reassigned.
    static let everywhereNames = ["jarvis"]

    func search() {
        task?.cancel()
        found = []
        error = nil
        progress = 0
        searching = true

        // Read before the task starts, and no longer guarded against: on
        // cellular this is nil, and that is not a reason to refuse to look.
        let base = Self.subnetPrefix()

        task = Task { [port] in
            // STEP ONE - the addresses that are true everywhere. A handful of
            // probes with a proper timeout, because a tailnet round trip over
            // 5G is not the 1.2 second affair a LAN one is.
            let anywhere = Self.everywhereNames + Defaults.addresses
            await self.sweep(anywhere, port: port, timeout: 4)
            progress = 0.2
            if Task.isCancelled { searching = false; return }

            // STEP TWO - the local sweep, if there is a local network at all.
            guard let base else {
                searching = false
                progress = 1
                if found.isEmpty {
                    error = "Nothing answered. Away from home the PC is reached over Tailscale - check Tailscale is switched on in the phone's settings, or type the address below."
                }
                return
            }

            // Forty at a time, in flat batches. Enough that the sweep finishes
            // in a second or two; few enough that iOS does not start refusing
            // sockets, which it does somewhere north of a couple of hundred
            // outstanding connections and which shows up as the scan quietly
            // finding nothing at all.
            let batch = 40
            var start = 1
            while start <= 254 {
                if Task.isCancelled { break }
                let end = min(254, start + batch - 1)
                await self.sweep((start...end).map { "\(base).\($0)" },
                                 port: port, timeout: 1.2)
                progress = 0.2 + 0.8 * Double(end) / 254.0
                start = end + 1
            }
            searching = false
            progress = 1
        }
    }

    /// Ask a list of hosts at once, and fold whatever answers into `found`.
    private func sweep(_ hosts: [String], port: UInt16,
                       timeout: TimeInterval) async {
        let hits = await withTaskGroup(of: FoundPC?.self,
                                       returning: [FoundPC].self) { group in
            for host in hosts {
                group.addTask {
                    await Discovery.probe(host: host, port: port,
                                          timeout: timeout)
                }
            }
            var out: [FoundPC] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        for pc in hits { merge(pc) }
    }

    /// ONE ROW PER PC, NOT ONE PER ADDRESS.
    ///
    /// The same machine now answers as `jarvis`, as 100.x and as 192.168.x, and
    /// three identical-looking rows would be a worse setup screen than the one
    /// this replaced. The address that answered FIRST is kept as the row's own,
    /// and because the everywhere-names are asked first that is the tailnet
    /// name - which is exactly the address you want written into the Keychain
    /// and reconnected to on a train. The rest become alternates.
    private func merge(_ pc: FoundPC) {
        guard let i = found.firstIndex(where: { $0.name == pc.name }) else {
            found.append(pc)
            return
        }
        var kept = found[i]
        for a in [pc.address] + pc.alternates {
            if a != kept.address && !kept.alternates.contains(a) {
                kept.alternates.append(a)
            }
        }
        found[i] = kept
    }

    func stop() {
        task?.cancel()
        task = nil
        searching = false
    }

    /// Is there a Jarvis at this address? Nil if not, a description if so.
    nonisolated static func probe(host: String, port: UInt16,
                                  timeout: TimeInterval = 1.2) async -> FoundPC? {
        guard let h = await hello(host: host, port: port, timeout: timeout) else {
            return nil
        }
        return FoundPC(name: h.name, address: host, port: port,
                       paired: h.paired,
                       alternates: h.addresses.filter { $0 != host })
    }

    nonisolated static func hello(host: String, port: UInt16,
                      timeout: TimeInterval = 4) async -> Hello? {
        guard let url = URL(string: "http://\(host):\(port)/api/hello") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              obj["jarvis"] as? Bool == true else { return nil }
        return Hello(name: obj["name"] as? String ?? host,
                     paired: obj["paired"] as? Bool ?? false,
                     addresses: obj["addresses"] as? [String] ?? [])
    }

    /// The first three octets of this phone's Wi-Fi address, e.g. "192.168.1".
    ///
    /// getifaddrs rather than anything friendlier, because there is no public
    /// API for it. en0 is Wi-Fi on every iPhone; en1..en4 cover the cases where
    /// it is not (a wired adapter, a personal hotspot client) and pdp_ip0 is
    /// deliberately excluded - a cellular address has no local subnet to sweep.
    nonisolated static func subnetPrefix() -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
        defer { freeifaddrs(ptr) }

        var best: String?
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = node {
            defer { node = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4, ip != "127.0.0.1" else { continue }
            let prefix = parts.dropLast().joined(separator: ".")
            if name == "en0" { return prefix }      // Wi-Fi wins outright
            if best == nil { best = prefix }
        }
        return best
    }

    // MARK: - pairing

    /// Exchange the spoken six-digit code for the long-lived key.
    nonisolated static func pair(host: String, port: UInt16,
                                 code: String) async throws -> String {
        guard let url = URL(string: "http://\(host):\(port)/api/pair") else {
            throw PairError.badAddress
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let device = await MainActor.run { UIDevice.current.name }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": String(code.filter(\.isNumber)),
            "device": device
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = obj?["token"] as? String else {
            throw PairError.refused(obj?["error"] as? String
                                    ?? "That code was wrong or has expired.")
        }
        return token
    }

    enum PairError: LocalizedError {
        case badAddress
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .badAddress: return "That address does not look right."
            case .refused(let why): return why
            }
        }
    }
}

// MARK: - the key, in the Keychain
//
// Not UserDefaults. This key can move the pointer and type on somebody's
// computer; UserDefaults is a plist inside the app container and is copied into
// unencrypted backups. kSecAttrAccessibleAfterFirstUnlock is the right class:
// the app needs it when it comes back from the background, which happens while
// the phone is locked, but it must not be readable when the device has never
// been unlocked since boot.
enum Vault {
    private static let service = "jarvis.remote.token"

    static func token(for pc: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pc,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for pc: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pc
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget(_ pc: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pc
        ] as CFDictionary)
    }
}

// MARK: - what the app remembers between launches
//
// Everything here is a hint, never a secret - the secret is in the Keychain
// above. The most important of them is the ADDRESS LIST: it is what lets the
// app reconnect after a walk out of the house without being told anything.
// The PC reports every address it answers on (netreach.py) and the app keeps
// the list, so the next launch tries the tailnet address and the home Wi-Fi
// address in turn rather than only the one that worked last time.
enum Defaults {
    private static let d = UserDefaults.standard

    static func saveAddresses(_ list: [String], port: UInt16) {
        d.set(list, forKey: "addresses")
        d.set(Int(port), forKey: "lastPort")
    }

    static var addresses: [String] {
        (d.array(forKey: "addresses") as? [String]) ?? []
    }

    static var port: UInt16 {
        let p = d.integer(forKey: "lastPort")
        return p == 0 ? 8765 : UInt16(p)
    }

    /// The MAC to send a magic packet to, so "turn my PC on" survives the PC
    /// being off - which is exactly when it cannot be asked for it.
    static var wakeMac: String {
        get { d.string(forKey: "wakeMac") ?? "" }
        set { d.set(newValue, forKey: "wakeMac") }
    }
}
