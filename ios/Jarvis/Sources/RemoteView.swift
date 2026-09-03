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

    // The keyboard. `typed` is a send buffer, not a document - see sync().
    @State private var typed = ""
    @State private var sentSoFar = ""
    @State private var keyboardUp = false
    /// When the picture was last tapped. The keyboard is only allowed up in
    /// the moment or so after one - see the onChange in `body`.
    @State private var lastTapAt: CFAbsoluteTime = 0
    @FocusState private var typingFocused: Bool

    // Click rings, cleared on a timer. Capped so a burst of clicks cannot
    // grow the view tree without bound.
    @State private var pings: [ClickPing] = []

    var body: some View {
        VStack(spacing: 0) {
            if !fullScreen { StatusBar() }
            if !fullScreen { screenPicker }
            viewer
            if keyboardUp { keyboardBar }
            if !fullScreen && !keyboardUp { controls }
        }
        // THE TAB BAR HAS TO GO, and this line is why "it won't full screen a
        // monitor" was true. The flag hid the status strip and the buttons and
        // dimmed the screen picker, and left the picture in a box with a tab
        // bar under it and a picker over it - about seventy points of chrome on
        // a phone, on both edges, which is not full screen by any reading. The
        // picker is now hidden outright rather than faded, and the tab bar this
        // view is inside is hidden here; nothing else can reach it.
        .toolbar(fullScreen ? .hidden : .visible, for: .tabBar)
        // THE KEYBOARD COMES UP BECAUSE YOU TAPPED A TEXT BOX, and for no
        // other reason.
        //
        // It used to come up whenever the PC reported that the focused control
        // takes typing - and remote.py answers that partly from the cursor
        // SHAPE, treating an I-beam as a yes. So merely dragging the pointer
        // across a page of text raised the keyboard, over and over, with
        // nothing pressed. Half the screen would disappear while you were
        // trying to look at it.
        //
        // A tap now opens a short window, and only a report that arrives inside
        // that window counts. That is the difference between "the caret is
        // somewhere typable" and "I just clicked a search bar", and the second
        // one is what was asked for. Everything after that is unchanged: the
        // field below is a real first responder, so what appears is the phone's
        // own keyboard, whatever iOS it is running.
        .onChange(of: link.cursor.acceptsTyping) { _, takes in
            guard live, takes, !keyboardUp else { return }
            guard CFAbsoluteTimeGetCurrent() - lastTapAt < 1.5 else { return }
            keyboardUp = true
            typed = ""; sentSoFar = ""
            typingFocused = true
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
                    let shown = ShownImage(view: geo.size, image: img.size)
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .gesture(pointerGesture(in: geo.size, image: img.size))

                    // The PC's own mouse, drawn on top. It is not in the JPEG:
                    // Windows leaves the cursor out of a framebuffer grab, so
                    // without this the picture has no pointer in it at all and
                    // there is no way to see what you are about to click.
                    PointerOverlay(cursor: link.cursor,
                                   display: display,
                                   shown: shown)

                    ForEach(pings) { $0 }
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

                // Full screen is the corner button, and ONLY the corner
                // button.
                //
                // It used to be a double tap on the picture as well, and that
                // was two bugs wearing one coat. The picture already carries a
                // drag recogniser with a zero minimum distance, so the two
                // competed and the double tap frequently never fired at all -
                // "it won't full screen when a monitor is selected". And when
                // it did fire, both taps had already gone to the PC as clicks,
                // so asking for full screen double-clicked whatever was under
                // your finger. A button cannot do either.
                VStack {
                    HStack {
                        Spacer()
                        Button { fullScreen.toggle() } label: {
                            Image(systemName: fullScreen
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .padding(8)
                    }
                    Spacer()
                    if fullScreen { fullScreenBar }
                }
            }
        }
    }

    /// A drag puts the pointer where your finger is; a tap clicks there.
    ///
    /// ABSOLUTE, NOT RELATIVE, AND THAT IS THE WHOLE OF "THE MOUSE IS BUGGY ON
    /// ANOTHER NETWORK".
    ///
    /// This used to send deltas: each move said "go 14 pixels right from
    /// wherever you are". Three things then went wrong at once, and every one
    /// of them is worse the further away the phone is.
    ///
    ///   * A delta is not self-contained. Lose one, reorder two, and the
    ///     pointer is permanently out of step with the finger for the rest of
    ///     the drag - there is nothing in a later packet that can correct it.
    ///     On a LAN that essentially never happens; over a tailnet being
    ///     relayed it happens constantly, and it reads exactly as "buggy".
    ///   * SwiftUI reports a drag at the display's refresh rate, so it sent up
    ///     to 120 packets a second. Over a relay that is a queue, and a queue
    ///     is lag that grows for as long as the finger keeps moving.
    ///   * The scale factor was the monitor's width over the view's width. On
    ///     ALL SCREENS that is a 5760-pixel union over a 390-point phone -
    ///     nearly fifteen desktop pixels per point - so the smallest tremor in
    ///     a finger threw the pointer across a monitor.
    ///
    /// An absolute position has none of those properties. Every packet carries
    /// the whole answer, so a lost one costs a single skipped frame and the
    /// next one is right again; the finger and the pointer cannot drift apart
    /// because the finger IS the position; and the union of three monitors maps
    /// as correctly as one does. It is also what the tap below has always done,
    /// so dragging and tapping finally agree with each other.
    ///
    /// Coalesced to one packet per frame at most - see flushPointer.
    private func pointerGesture(in view: CGSize, image: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if !dragging,
                   hypot(v.translation.width, v.translation.height) > 6 {
                    dragging = true
                }
                guard dragging else { return }
                pending = v.location
                flushPointer(in: view, image: image)
            }
            .onEnded { v in
                defer { dragging = false; pending = nil; lastSent = 0 }
                if dragging {
                    // The last position ALWAYS goes, throttle or no throttle.
                    // Dropping the final packet of a drag is how a pointer ends
                    // up a few pixels short of the thing being dragged onto.
                    if let pt = absolute(v.location, in: view, image: image) {
                        link.moveAbsolute(x: pt.0, y: pt.1)
                    }
                    return
                }
                tap(v.location, in: view, image: image)
            }
    }

    @State private var dragging = false
    @State private var pending: CGPoint?
    @State private var lastSent: CFAbsoluteTime = 0

    /// At most one pointer packet every 16 ms, carrying the newest position.
    ///
    /// Not a timer and not a buffer: there is only ever one useful position -
    /// the latest - so anything older is simply dropped. Sixty a second is
    /// smoother than any screen stream this is drawn over and an eighth of what
    /// the old code put on the wire.
    private func flushPointer(in view: CGSize, image: CGSize) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= 0.016, let p = pending else { return }
        lastSent = now
        pending = nil
        guard let pt = absolute(p, in: view, image: image) else { return }
        link.moveAbsolute(x: pt.0, y: pt.1)
    }

    /// A point in the view, as a real pixel on the monitor being watched.
    ///
    /// Goes through ShownImage, the same letterbox maths the pointer overlay
    /// uses, so what is drawn and what is sent cannot disagree.
    private func absolute(_ point: CGPoint, in view: CGSize,
                          image: CGSize) -> (Int, Int)? {
        guard let d = display else { return nil }
        let shown = ShownImage(view: view, image: image)
        let fx = (point.x - shown.origin.x) / shown.size.width
        let fy = (point.y - shown.origin.y) / shown.size.height
        // Clamped rather than rejected: a finger that slides off the edge of
        // the picture mid-drag should pin the pointer to that edge, not freeze
        // it wherever it happened to be when the finger left.
        let cx = min(max(fx, 0), 1), cy = min(max(fy, 0), 1)
        return (d.x + Int(cx * CGFloat(d.w)), d.y + Int(cy * CGFloat(d.h)))
    }

    private var display: Display? {
        link.displays.first(where: { $0.index == monitor })
    }

    private func tap(_ point: CGPoint, in view: CGSize, image: CGSize) {
        // Outside the picture (the letterbox bars) is not a click.
        let shown = ShownImage(view: view, image: image)
        let fx = (point.x - shown.origin.x) / shown.size.width
        let fy = (point.y - shown.origin.y) / shown.size.height
        guard (0...1).contains(fx), (0...1).contains(fy) else { return }
        guard let pt = absolute(point, in: view, image: image) else { return }
        // Stamped BEFORE the click goes out, so the PC's answer about whether
        // what was clicked takes typing arrives inside the window that raises
        // the keyboard. See the onChange in `body`.
        lastTapAt = CFAbsoluteTimeGetCurrent()
        link.moveAbsolute(x: pt.0, y: pt.1)
        link.click(.left)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        ring(at: point, button: .left)
    }

    /// Leave a ring where a click was sent.
    ///
    /// Over a link with real latency there is otherwise no way to tell a click
    /// that landed from one the PC was too busy to take, and the instinct when
    /// you cannot tell is to tap again - which turns a remote single click into
    /// a double click on something that did not want one.
    private func ring(at point: CGPoint, button: MouseButton) {
        let ping = ClickPing(at: point, button: button)
        pings.append(ping)
        if pings.count > 6 { pings.removeFirst(pings.count - 6) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            pings.removeAll { $0.id == ping.id }
        }
    }

    // MARK: - the keyboard
    //
    // "click and type with the virtual keyboard, for all things typing, when
    //  clicked in the type box or search bar"
    //
    // Two things make that work. The first is knowing WHEN: remote.py now
    // reports whether the focused control on the PC accepts typing - it asks
    // Windows for the foreground thread's caret, and treats an I-beam cursor
    // as the same answer - and that arrives on every cursor packet. So the
    // keyboard comes up the moment a text box is clicked, without being asked
    // for. (This is where the phone beats a browser: UIKit will raise the
    // keyboard from a programmatic focus, where Safari only does it inside a
    // user gesture.)
    //
    // The second is WHAT to send. A phone keyboard is not a keyboard: it
    // autocorrects, it predicts, and it replaces the whole word you just typed
    // when you hit space. Forwarding keystrokes would forward the wrong ones.
    // So the field's VALUE is diffed against what has already been sent - the
    // common prefix stays, the rest is backspaced off the PC and the new tail
    // typed. An autocorrect that rewrites "teh" into "the" arrives on the PC as
    // two backspaces and "he", which is exactly what happened.

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            TextField("type - it goes to the PC as you type", text: $typed, axis: .horizontal)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typingFocused)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.bg)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.hot, lineWidth: 1)))
                .submitLabel(.return)
                .onSubmit {
                    sync()
                    link.key("enter")
                    typed = ""; sentSoFar = ""
                    // Keep it up: pressing return in a search box is rarely the
                    // last thing anyone wants to type.
                    typingFocused = true
                }
                .onChange(of: typed) { _, _ in sync() }

            HStack(spacing: 7) {
                ForEach(["escape", "tab", "backspace", "left", "right", "enter"], id: \.self) { name in
                    Button {
                        sync()
                        link.key(name)
                        // Backspace and the arrows move the PC's own caret, so
                        // what this phone believes it has sent is no longer
                        // true. Resetting the buffer stops the next keystroke
                        // trying to correct text that is not there any more.
                        typed = ""; sentSoFar = ""
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(keyLabel(name))
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .stroke(Palette.hot, lineWidth: 1))
                            .foregroundStyle(Palette.hot)
                    }
                }
                Button {
                    keyboardUp = false
                    typingFocused = false
                } label: {
                    Text("DONE")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Palette.hot.opacity(0.22)))
                        .foregroundStyle(Palette.ink)
                }
            }
        }
        .padding(9)
        .background(Palette.panel)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.hot),
                 alignment: .top)
    }

    private func keyLabel(_ name: String) -> String {
        switch name {
        case "escape": return "ESC"
        case "tab": return "TAB"
        case "backspace": return "\u{232B}"
        case "left": return "\u{2190}"
        case "right": return "\u{2192}"
        case "enter": return "\u{21B5}"
        default: return name
        }
    }

    /// Send only what changed, as backspaces and a new tail.
    private func sync() {
        guard typed != sentSoFar else { return }
        let now = Array(typed), before = Array(sentSoFar)
        var k = 0
        while k < min(now.count, before.count), now[k] == before[k] { k += 1 }
        for _ in 0..<(before.count - k) { link.key("backspace") }
        if now.count > k { link.type(String(now[k...])) }
        sentSoFar = typed
        // The field is a send buffer, not a document. Left to grow it would end
        // up a paragraph of already-typed text on one line, so once a word is
        // safely on the PC only the tail is kept.
        if sentSoFar.count > 120 {
            sentSoFar = String(sentSoFar.suffix(40))
            typed = sentSoFar
        }
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
