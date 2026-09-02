//
//  RemoteView.swift - the Remote tab.
//
//      "when i control (remote section in app) i can select and see all screens
//       in full screen live and i can hear mic and talk through, and i can turn
//       my pc on and off"
//
//  Four things in one place, because they are one activity: you are at the PC
//  without being at the PC.
//
//    SCREENS   every display, individually or all of them at once, live, and
//              full screen means FULL screen - the tab bar, the status strip
//              and the safe areas all go, and the phone turns sideways.
//    POINTER   the picture is the trackpad. Drag to move, tap to click, and a
//              tap maps to the real pixel on whichever monitor is being watched,
//              which on a three-monitor desk means going through the geometry
//              the PC reported rather than assuming the union starts at 0,0.
//    AUDIO     LISTEN plays the PC's microphone here; TALK is push-to-hold and
//              sends this phone's microphone there. See Audio.swift.
//    POWER     sleep, hibernate, shut down - and wake, which does not go over
//              the connection because there is nothing at the other end of it
//              when the PC is off. See Wake.swift.
//
//  ---------------------------------------------------------------------------
//  THE FRAME RATE IS NOT A SLIDER SET TO ITS MAXIMUM
//
//  Every frame is a full JPEG encode on the PC of up to three 1080p displays,
//  on a machine whose entire performance story is about not doing avoidable
//  work. And every frame is a JPEG DECODE here, on the main thread, inside a
//  SwiftUI update. So the stream is asked for at a rate that suits what is
//  being done with it, and the tab stops it on the way out - encoding frames of
//  three monitors for a view nobody is looking at is a straight tax on the
//  machine Jarvis is trying to keep responsive.
//
//  The defaults are deliberate: 12 fps and 1600px wide over a LAN, 8 fps and
//  1100px when the connection came in over the tailnet, because that second one
//  is somebody's mobile data.
//

import SwiftUI
import UIKit

struct RemoteTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Link
    @StateObject private var audio = AudioLink()

    @State private var live = false
    @State private var monitor = 0
    @State private var fullScreen = false
    @State private var showPower = false
    @State private var confirmAction: PowerAction?
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            if !fullScreen { StatusBar() }
            screenPicker
            viewer
            if !fullScreen { controls }
        }
        .background(Palette.bg.ignoresSafeArea())
        .statusBarHidden(fullScreen)
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        .animation(.easeInOut(duration: 0.28), value: fullScreen)
        .onAppear { link.attach(audio: audio) }
        .onChange(of: monitor) { _, _ in if live { pushScreen() } }
        .onChange(of: link.connected) { _, up in
            // A reconnect starts a NEW client on the PC with its own screen and
            // listen settings, both off by default. Without this, coming back
            // from a lock screen leaves the app showing LIVE and LISTEN lit with
            // nothing arriving, which reads as the feature being broken.
            if up {
                if live { pushScreen() }
                if audio.listening { link.command("listen", ["on": true]) }
            }
        }
        .onDisappear { stopEverything() }
        .alert("Are you sure?", isPresented: Binding(
            get: { confirmAction != nil },
            set: { if !$0 { confirmAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmAction = nil }
            Button(confirmAction?.title ?? "", role: .destructive) {
                if let a = confirmAction { run(a) }
                confirmAction = nil
            }
        } message: {
            Text(confirmAction?.warning ?? "")
        }
    }

    // MARK: - screens

    private var screenPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(link.displays) { d in
                    Button {
                        monitor = d.index
                        if !live { live = true; pushScreen() }
                    } label: {
                        Text(d.all ? "ALL SCREENS" : "SCREEN \(d.index)")
                            .font(.system(size: 10, weight: .semibold,
                                          design: .monospaced))
                            .kerning(1.5)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(monitor == d.index
                                        ? Palette.hot.opacity(0.18) : Palette.panel)
                            .foregroundStyle(monitor == d.index ? Palette.hot : Palette.dim)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(monitor == d.index ? Palette.hot : Palette.line,
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                if link.displays.isEmpty {
                    Text("no displays reported")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, fullScreen ? 4 : 8)
        }
        .background(Palette.bg)
        .opacity(fullScreen ? 0.35 : 1)
    }

    private var viewer: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let data = link.frame, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .gesture(pointerGesture(in: geo.size, image: img.size))
                } else {
                    VStack(spacing: 10) {
                        Text(live ? "waiting for a frame…" : "pick a screen")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                        if !link.connected {
                            Text(offlineHint)
                                .font(.system(size: 11))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Palette.dim)
                                .padding(.horizontal, 30)
                        }
                    }
                }

                // Full screen is a double tap on the picture, which is what
                // everyone tries first, plus a corner button so it is
                // discoverable at all.
                VStack {
                    HStack {
                        Spacer()
                        Button { fullScreen.toggle() } label: {
                            Image(systemName: fullScreen
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .padding(9)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .padding(10)
                    }
                    Spacer()
                    if fullScreen { fullScreenBar }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { fullScreen.toggle() }
        }
    }

    /// A drag is a pointer move; a tap is a click on the real pixel.
    ///
    /// Both in one gesture rather than two recognisers, because a tap and a
    /// very short drag are the same event on a touchscreen - a finger always
    /// moves a little - and two competing recognisers means every click is also
    /// a small pointer nudge, which lands it on the wrong thing.
    private func pointerGesture(in view: CGSize, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                guard v.translation.width != 0 || v.translation.height != 0 else { return }
                if hypot(v.translation.width, v.translation.height) > 6 {
                    dragging = true
                    let dx = v.location.x - lastDrag.x
                    let dy = v.location.y - lastDrag.y
                    if lastDrag != .zero {
                        // Scaled to the real desktop: a finger crossing the
                        // phone should cross the monitor, not a phone-sized
                        // patch of it.
                        let d = display
                        let sx = CGFloat(d?.w ?? 1920) / max(1, view.width)
                        let sy = CGFloat(d?.h ?? 1080) / max(1, view.height)
                        link.move(dx: Int(dx * sx), dy: Int(dy * sy))
                    }
                    lastDrag = v.location
                }
            }
            .onEnded { v in
                defer { dragging = false; lastDrag = .zero }
                guard !dragging else { return }
                tap(v.location, in: view, image: image)
            }
    }

    @State private var dragging = false
    @State private var lastDrag: CGPoint = .zero

    private var display: Display? {
        link.displays.first(where: { $0.index == monitor })
    }

    private func tap(_ point: CGPoint, in view: CGSize, image: CGSize) {
        guard let d = display else { return }
        let scale = min(view.width / image.width, view.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (view.width - shown.width) / 2,
                             y: (view.height - shown.height) / 2)
        let fx = (point.x - origin.x) / shown.width
        let fy = (point.y - origin.y) / shown.height
        guard (0...1).contains(fx), (0...1).contains(fy) else { return }
        link.moveAbsolute(x: d.x + Int(fx * CGFloat(d.w)),
                          y: d.y + Int(fy * CGFloat(d.h)))
        link.click(.left)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - the bars

    /// In full screen the controls collapse to one translucent strip, so the
    /// picture keeps the whole display and TALK is still reachable one-handed.
    private var fullScreenBar: some View {
        HStack(spacing: 14) {
            liveButton
            listenButton
            talkButton
            Spacer()
            Text(link.connected ? String(format: "%.0f ms", link.latencyMs) : "offline")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                liveButton
                listenButton
                talkButton
                Button { showPower = true } label: {
                    Label("POWER", systemImage: "power")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Palette.panel)
                        .foregroundStyle(Palette.ink)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text(whereLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                Spacer()
                if audio.listening || audio.talking {
                    Text(audio.stats)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
            }

            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let e = audio.lastError {
                Text(e).font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Palette.bg)
        .sheet(isPresented: $showPower) {
            PowerSheet(reach: link.reach,
                       connected: link.connected,
                       onAction: { act in
                           showPower = false
                           if act.destructive { confirmAction = act } else { run(act) }
                       })
            .presentationDetents([.medium])
        }
    }

    private var liveButton: some View {
        Key(live ? "STOP" : "LIVE", active: live) {
            live.toggle()
            pushScreen()
        }
    }

    private var listenButton: some View {
        Key(audio.listening ? "MUTE" : "LISTEN", active: audio.listening) {
            if audio.listening {
                audio.stopListening()
                link.command("listen", ["on": false])
            } else {
                audio.startListening()
                link.command("listen", ["on": true])
            }
        }
    }

    /// Push to hold, not a toggle.
    ///
    /// A toggle is how an open microphone gets left open in a pocket. Holding
    /// it also matches what the thing actually is - a walkie-talkie into
    /// another room - and it means releasing is instant and unambiguous.
    private var talkButton: some View {
        Text(audio.talking ? "TALKING" : "TALK")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .kerning(1.5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(audio.talking ? Palette.hot.opacity(0.22) : Palette.panel)
            .foregroundStyle(audio.talking ? Palette.hot : Palette.ink)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(audio.talking ? Palette.hot : Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !audio.talking else { return }
                        audio.startTalking()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .onEnded { _ in
                        audio.stopTalking()
                        link.command("talkback", ["on": false])
                    }
            )
    }

    // MARK: - power

    private func run(_ act: PowerAction) {
        switch act {
        case .wake:
            let mac = link.reach.wake.mac.isEmpty ? Defaults.wakeMac
                                                  : link.reach.wake.mac
            guard !mac.isEmpty else {
                note = "I do not know this PC's network card yet. Connect to it "
                     + "once on Wi-Fi and I will remember how to wake it."
                return
            }
            Defaults.wakeMac = mac
            note = "Sending the wake packet…"
            Wake.send(mac: mac, knownAddresses: Defaults.addresses) { sent in
                note = sent
                    ? "Wake packet sent. It only travels on the local network, "
                    + "so this works when the phone is on the same Wi-Fi."
                    : "The wake packet could not be sent from this network."
            }
        default:
            link.command("power", ["action": act.wire]) { result in
                note = (result["output"] as? String)
                    ?? (result["error"] as? String)
                    ?? ""
            }
        }
    }

    // MARK: - wording

    private var whereLine: String {
        guard link.connected else { return "not connected" }
        let a = link.activeAddress
        let kind = link.reach.addresses.first { $0.address == a }?.kind
        switch kind {
        case "tailnet": return "connected over the internet · \(a)"
        case "lan":     return "connected on this network · \(a)"
        default:        return "connected · \(a)"
        }
    }

    private var offlineHint: String {
        if link.reach.anywhere {
            return "Reconnecting. This PC is reachable from anywhere, so this "
                 + "should come back on mobile data too."
        }
        return link.reach.advice.isEmpty
            ? "Reconnecting…" : link.reach.advice
    }

    // MARK: - stream control

    private func pushScreen() {
        // Sized for the connection. A tailnet connection is, by definition, the
        // away-from-home one - which is somebody's mobile data.
        let overInternet = link.reach.addresses
            .first { $0.address == link.activeAddress }?.isAnywhere ?? false
        link.command("screen", [
            "on": live,
            "monitor": monitor,
            "fps": overInternet ? 8 : 12,
            "width": overInternet ? 1100 : 1600,
            "quality": overInternet ? 45 : 62,
        ])
    }

    private func stopEverything() {
        if live { live = false; link.command("screen", ["on": false]) }
        if audio.listening {
            audio.stopListening()
            link.command("listen", ["on": false])
        }
        if audio.talking {
            audio.stopTalking()
            link.command("talkback", ["on": false])
        }
        fullScreen = false
    }
}

// MARK: - what the power button offers

enum PowerAction: Identifiable, Hashable {
    case wake, sleep, hibernate, lock, restart, shutdown

    var id: String { wire }

    var wire: String {
        switch self {
        case .wake:      return "wake"
        case .sleep:     return "sleep"
        case .hibernate: return "hibernate"
        case .lock:      return "lock"
        case .restart:   return "restart"
        case .shutdown:  return "shutdown"
        }
    }

    var title: String {
        switch self {
        case .wake:      return "Wake"
        case .sleep:     return "Sleep"
        case .hibernate: return "Hibernate"
        case .lock:      return "Lock"
        case .restart:   return "Restart"
        case .shutdown:  return "Shut Down"
        }
    }

    var icon: String {
        switch self {
        case .wake:      return "power"
        case .sleep:     return "moon.zzz"
        case .hibernate: return "snowflake"
        case .lock:      return "lock"
        case .restart:   return "arrow.clockwise"
        case .shutdown:  return "power.circle"
        }
    }

    var destructive: Bool {
        self == .restart || self == .shutdown
    }

    var warning: String {
        switch self {
        case .restart:
            return "This closes everything that is open on the PC and restarts it."
        case .shutdown:
            return "This closes everything that is open and turns the PC off. "
                 + "You will only be able to turn it back on from the same "
                 + "Wi-Fi, or not at all if Wake-on-LAN is not set up."
        default:
            return ""
        }
    }

    var blurb: String {
        switch self {
        case .wake:
            return "Sends a wake packet on the local network."
        case .sleep:
            return "The one that can be undone from here. Sleeping keeps the "
                 + "network card fed, so the PC can be woken again."
        case .hibernate:
            return "Writes memory to disk and powers down. Everything is where "
                 + "you left it when it comes back."
        case .lock:
            return "Locks the screen and leaves everything running."
        case .restart:
            return "Closes everything and restarts."
        case .shutdown:
            return "Closes everything and turns it off."
        }
    }
}

private struct PowerSheet: View {
    let reach: Reach
    let connected: Bool
    let onAction: (PowerAction) -> Void

    private var actions: [PowerAction] {
        // Wake is offered whether or not the PC is answering, because the whole
        // point of it is the case where it is not. Everything else needs a
        // connection to travel down.
        connected ? [.sleep, .hibernate, .lock, .restart, .shutdown, .wake]
                  : [.wake]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(actions) { a in
                        Button { onAction(a) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: a.icon)
                                    .frame(width: 22)
                                    .foregroundStyle(a.destructive ? .red : Palette.hot)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title)
                                        .foregroundStyle(a.destructive ? .red : Palette.ink)
                                    Text(a.blurb)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.dim)
                                }
                            }
                        }
                    }
                }

                // The honest paragraph. It is here rather than absent because a
                // wake button that quietly does nothing on mobile data is worse
                // than one that says what it needs.
                Section("Turning it back on") {
                    if !reach.wake.armed && !reach.wake.help.isEmpty {
                        Label(reach.wake.help, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    if !reach.wake.note.isEmpty {
                        Text(reach.wake.note)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.dim)
                    }
                    if !reach.wake.mac.isEmpty {
                        HStack {
                            Text("Network card").foregroundStyle(Palette.dim)
                            Spacer()
                            Text(reach.wake.mac)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .navigationTitle("Power")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
