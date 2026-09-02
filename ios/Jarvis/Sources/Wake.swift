//
//  Wake.swift - turning the PC on.
//
//      "and i can turn my pc on and off"
//
//  Off is easy and goes over the existing connection: `power` with sleep,
//  hibernate or shutdown, straight into system.power_action on the PC, the same
//  function the voice command uses.
//
//  ON is the interesting half, and it cannot use the connection, because the
//  thing at the other end of the connection is off. There is no software running
//  to receive anything. What is still awake is the NETWORK CARD, sitting in a
//  low-power state watching the wire for one specific pattern - six 0xFF bytes
//  followed by its own MAC address repeated sixteen times - and wired to pull
//  the board's power rail when it sees it. That is Wake-on-LAN, and this file
//  sends that packet.
//
//  ---------------------------------------------------------------------------
//  WHAT THIS CAN AND CANNOT DO, PLAINLY
//
//  A magic packet is a layer 2 broadcast. Broadcasts do not route. So:
//
//    ON THE SAME WI-FI          works. This is the common case - waking the PC
//                               from bed or from the sofa - and it needs
//                               nothing but the MAC, which the PC told the app
//                               the last time they spoke.
//
//    ON MOBILE DATA             the packet cannot be delivered by this phone at
//                               all, and Tailscale cannot carry it either,
//                               because the PC's tailnet node is off with the
//                               PC. Something already awake on that LAN has to
//                               put it on the wire: a router with a Wake-on-LAN
//                               feature, or any other always-on machine.
//
//  The honest answer for away-from-home is therefore SLEEP rather than shut
//  down: a sleeping PC still has a network card being fed, still holds its
//  tailnet address, and wakes from the same packet - and it is what the app
//  offers first for that reason.
//
//  The app says all of this in the interface rather than presenting a button
//  that silently does nothing, which is what every remote-power feature that
//  has ever annoyed anybody does.
//

import Foundation
import Network

enum Wake {

    /// The 102 bytes: 0xFF six times, then the MAC sixteen times.
    static func magicPacket(for mac: String) -> Data? {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Every broadcast address worth trying, given the PC's known addresses.
    ///
    /// The global broadcast 255.255.255.255 alone is not enough and is the usual
    /// reason a magic packet "does nothing": most Wi-Fi access points drop it,
    /// while forwarding the DIRECTED broadcast for their own subnet
    /// (192.168.1.255) perfectly happily. So the subnet broadcast is derived
    /// from each LAN address the PC reported and both are sent.
    static func broadcastTargets(from knownAddresses: [String]) -> [String] {
        var out = ["255.255.255.255"]
        for a in knownAddresses {
            let parts = a.split(separator: ".")
            guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { continue }
            let subnet = parts[0...2].joined(separator: ".") + ".255"
            if !out.contains(subnet) { out.append(subnet) }
        }
        return out
    }

    /// Send the packet. Ports 9 and 7 both, because which one a given card
    /// watches is a firmware decision and there is no cost to covering both.
    ///
    /// Fire and forget by nature: nothing acknowledges a magic packet, and the
    /// only real confirmation is the PC answering the app a minute later. The
    /// completion reports whether it could be SENT, which is a different and
    /// much weaker claim, and the interface words it that way.
    @discardableResult
    static func send(mac: String, knownAddresses: [String],
                     done: ((Bool) -> Void)? = nil) -> Bool {
        guard let packet = magicPacket(for: mac) else {
            done?(false)
            return false
        }

        let params = NWParameters.udp
        // Without this the send is refused: a broadcast is not an ordinary
        // datagram and iOS requires the option to be asked for explicitly.
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack
            .internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        var anySent = false
        let group = DispatchGroup()

        for target in broadcastTargets(from: knownAddresses) {
            for port in [UInt16(9), UInt16(7)] {
                guard let p = NWEndpoint.Port(rawValue: port) else { continue }
                let conn = NWConnection(
                    host: NWEndpoint.Host(target),
                    port: p, using: params)
                group.enter()
                var finished = false
                let finish: (Bool) -> Void = { ok in
                    guard !finished else { return }
                    finished = true
                    if ok { anySent = true }
                    conn.cancel()
                    group.leave()
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: packet, completion: .contentProcessed { err in
                            finish(err == nil)
                        })
                    case .failed, .cancelled:
                        finish(false)
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .utility))
                // A UDP "connection" to a broadcast address that goes nowhere
                // never fails and never becomes ready; without a deadline the
                // group would never complete.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    finish(false)
                }
            }
        }

        group.notify(queue: .main) { done?(anySent) }
        return true
    }
}
