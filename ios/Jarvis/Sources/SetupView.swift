//
//  SetupView.swift - finding the PC and pairing with it.
//
//  Two paths, in the order they should be tried: ask Discovery, which tries the
//  PC's tailnet name first and only then sweeps this phone's own subnet, and,
//  for the networks where neither works - a guest VLAN with client isolation, a
//  /16, Tailscale switched off - type an address or a name by hand. Both end at
//  the same place: a six-digit code that Jarvis reads out loud, exchanged for a
//  key that goes in the Keychain.
//
//  The field below takes a NAME as readily as an address, which is why its
//  keyboard is the ordinary one and not the number pad it used to be. Typing
//  `jarvis` is the fastest way out of every away-from-home failure there is,
//  and it could not be typed at all on a decimal pad.
//
//  The code is spoken rather than shown as a QR because of how this is actually
//  used: he is across the room, the PC is over there, and asking "Jarvis, pair
//  my phone" and hearing six digits is faster than walking over to point a
//  camera at a screen.
//

import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var discovery = Discovery()

    @State private var manualHost = ""
    @State private var manualPort = "8765"
    @State private var code = ""
    @State private var target: FoundPC?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                header

                // Said out loud, because it is the difference between "this app
                // has forgotten my PC" and "this app is still looking for it".
                // The link goes on cycling every address it knows while this
                // page is up, so a phone that simply arrived home a second too
                // early lands on the tabs by itself.
                if model.retryingBehind, let known = model.pc {
                    VStack(spacing: 6) {
                        Text("still trying to reach \(known.name.uppercased())")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.hot)
                        Text("It will come back on its own the moment it "
                             + "answers. Pick it below to use a different "
                             + "address.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 22)
                }

                if let target {
                    pairing(for: target)
                } else {
                    finder
                }

                if let message {
                    Text(message)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if target == nil && model.canDismissSetup {
                    VStack(spacing: 14) {
                        Button("back") { model.dismissSetup() }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.hot)
                        Button("forget this PC") { model.forget() }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .onAppear {
            discovery.search()
            // Pre-filled with the name that works from anywhere rather than
            // left blank. On a strange network the sweep below finds nothing,
            // and the one thing that would have worked - typing `jarvis` - is
            // the thing nobody thinks to try. Having it already in the box
            // turns the away-from-home case into one tap on CONNECT.
            if manualHost.isEmpty {
                manualHost = Discovery.everywhereNames.first ?? "jarvis"
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("J.A.R.V.I.S.")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .kerning(6)
                .foregroundStyle(Palette.ink)
            Text("connect to your PC")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.dim)
        }
    }

    // MARK: - finding

    private var finder: some View {
        VStack(spacing: 18) {
            if discovery.searching {
                ProgressView().tint(Palette.hot)
                Text(discovery.progress < 0.2
                     ? "looking over Tailscale…" : "looking on this network…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.dim)
            }

            ForEach(discovery.found) { pc in
                Button { choose(pc) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pc.name)
                                .font(.system(size: 15, weight: .semibold,
                                              design: .monospaced))
                                .foregroundStyle(Palette.ink)
                            Text("\(pc.address):\(String(pc.port))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.dim)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Palette.hot)
                    }
                    .padding(14)
                    .background(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 22)
            }

            if !discovery.searching && discovery.found.isEmpty {
                Text(discovery.error
                     ?? "Nothing answered. Make sure Jarvis is running with\nJARVIS_REMOTE=1 — and away from home, that\nTailscale is switched on here and on the PC.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Button("search again") { discovery.search() }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.hot)

            Divider().background(Palette.line).padding(.horizontal, 40)

            VStack(spacing: 12) {
                Text("or type a name or address —  jarvis  works anywhere")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    field("jarvis", text: $manualHost)
                        .keyboardType(.default)
                    field("8765", text: $manualPort)
                        .keyboardType(.numberPad)
                        .frame(width: 90)
                }
                Key("CONNECT") { manual() }
                    .frame(width: 220)
                    .disabled(manualHost.isEmpty)
            }
            .padding(.horizontal, 22)
        }
    }

    // MARK: - pairing

    private func pairing(for pc: FoundPC) -> some View {
        VStack(spacing: 18) {
            Text(pc.name)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink)

            Text("Say “Jarvis, pair my phone” and type the six digits he reads back.")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .kerning(10)
                .foregroundStyle(Palette.ink)
                .padding(14)
                .background(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 40)
                .onChange(of: code) { _, v in
                    let digits = v.filter(\.isNumber)
                    if digits != v { code = String(digits.prefix(6)) }
                    else if digits.count > 6 { code = String(digits.prefix(6)) }
                    // Six digits is the whole code; there is nothing to confirm.
                    if code.count == 6 && !busy { pair(with: pc) }
                }

            if busy { ProgressView().tint(Palette.hot) }

            Button("choose a different PC") {
                target = nil
                code = ""
                message = nil
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.dim)
        }
    }

    // MARK: - actions

    private func choose(_ pc: FoundPC) {
        discovery.stop()
        message = nil
        // Already paired on this phone? Then there is nothing to ask for.
        if let saved = Vault.token(for: pc.id) {
            model.connect(to: pc, token: saved)
            return
        }
        target = pc
    }

    private func manual() {
        let port = UInt16(manualPort) ?? 8765
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        busy = true
        message = nil
        Task {
            if let h = await Discovery.hello(host: host, port: port) {
                busy = false
                choose(FoundPC(name: h.name, address: host, port: port,
                               paired: h.paired,
                               alternates: h.addresses.filter { $0 != host }))
            } else {
                busy = false
                message = "Nothing answered at \(host):\(port)."
            }
        }
    }

    private func pair(with pc: FoundPC) {
        busy = true
        message = nil
        Task {
            do {
                let token = try await Discovery.pair(host: pc.address,
                                                     port: pc.port, code: code)
                busy = false
                model.connect(to: pc, token: token)
            } catch {
                busy = false
                code = ""
                message = error.localizedDescription
            }
        }
    }

    private func field(_ placeholder: String,
                       text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(12)
            .background(Palette.panel)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(Palette.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(Palette.ink)
            .font(.system(.body, design: .monospaced))
    }
}
