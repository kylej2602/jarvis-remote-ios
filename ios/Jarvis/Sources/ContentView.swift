//
//  ContentView.swift - the app itself.
//
//  Four tabs, and the division between them is the honest one:
//
//    CONTROL   native. The trackpad, the buttons, the keyboard. Everything on
//              this tab has to answer in single-digit milliseconds, so none of
//              it goes anywhere near a web view.
//    SCREEN    native. JPEG frames straight from the socket into an Image, and
//              a tap maps to a real pixel on whichever of the three monitors is
//              being watched.
//    HUD       the REAL Jarvis HUD, index.html served from the PC, in a
//              WKWebView. Not a phone-shaped imitation of it - the same file
//              the desktop loads, with js/remote-bridge.js standing in for
//              WebView2. This is "the same ui ... in app or on pc", literally.
//    TALK      the transcript and a way to say something, mirrored live from
//              main.ui_call.
//

import SwiftUI
import UIKit
import WebKit

@main
struct JarvisApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.link)
                .preferredColorScheme(.dark)
                .tint(Palette.hot)
        }
    }
}

enum Palette {
    static let bg    = Color(red: 0.004, green: 0.016, blue: 0.047)
    static let panel = Color(red: 0.02,  green: 0.05,  blue: 0.10)
    static let ink   = Color(red: 0.81,  green: 0.91,  blue: 1.0)
    static let dim   = Color(red: 0.36,  green: 0.50,  blue: 0.62)
    static let hot   = Color(red: 0.21,  green: 0.82,  blue: 1.0)
    static let line  = Color(red: 0.05,  green: 0.16,  blue: 0.27)
}

@MainActor
final class AppModel: ObservableObject {
    // NOT @Published, and it is handed to the view tree as its own environment
    // object below. A nested ObservableObject is not observed transitively:
    // SwiftUI watches AppModel, a change inside Link never reaches it, and the
    // connection dot and the latency readout would have sat still for ever.
    let link = Link()
    @Published var pc: FoundPC?
    @Published var token: String = ""
    @Published var connectedOnce = false

    func connect(to pc: FoundPC, token: String) {
        self.pc = pc
        self.token = token
        Vault.save(token, for: pc.id)
        UserDefaults.standard.set(pc.address, forKey: "lastHost")
        UserDefaults.standard.set(Int(pc.port), forKey: "lastPort")
        UserDefaults.standard.set(pc.name, forKey: "lastName")
        link.connect(host: pc.address, port: pc.port, token: token)
        connectedOnce = true
    }

    /// Reconnect to whatever was used last, if its key is still in the Keychain.
    func restore() -> Bool {
        let d = UserDefaults.standard
        guard let host = d.string(forKey: "lastHost") else { return false }
        let port = UInt16(d.integer(forKey: "lastPort"))
        let name = d.string(forKey: "lastName") ?? host
        let pc = FoundPC(name: name, address: host,
                         port: port == 0 ? 8765 : port, paired: true)
        guard let token = Vault.token(for: pc.id) else { return false }
        connect(to: pc, token: token)
        return true
    }

    func forget() {
        if let pc { Vault.forget(pc.id) }
        link.disconnect()
        pc = nil
        connectedOnce = false
    }

    var hudURL: URL? {
        guard let pc else { return nil }
        let t = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? token
        return URL(string: "http://\(pc.address):\(pc.port)/hud?token=\(t)")
    }
}

// MARK: - root

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        Group {
            if model.connectedOnce {
                TabView(selection: $tab) {
                    ControlTab().tabItem { Label("Control", systemImage: "rectangle.and.hand.point.up.left") }.tag(0)
                    ScreenTab().tabItem { Label("Screen", systemImage: "display") }.tag(1)
                    HUDTab().tabItem { Label("HUD", systemImage: "circle.hexagongrid") }.tag(2)
                    TalkTab().tabItem { Label("Talk", systemImage: "waveform") }.tag(3)
                }
            } else {
                SetupView()
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .onAppear { _ = model.restore() }
    }
}

// MARK: - the status strip, on every tab

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Link

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(link.connected ? Palette.hot : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: link.connected ? Palette.hot : .red, radius: 5)
            Text(model.pc?.name.uppercased() ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(2)
                .foregroundStyle(Palette.ink)
            Spacer()
            // The number that says whether this is fast. Shown always, because
            // "quick by the millisecond" is a claim that ought to be checkable.
            Text(link.connected
                 ? String(format: "%.1f ms", link.latencyMs) : "offline")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.line),
                 alignment: .bottom)
    }
}

// MARK: - control

struct ControlTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Link
    @State private var typed = ""
    @State private var dragLock = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 12) {
            StatusBar()

            Trackpad(link: model.link)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(RadialGradient(colors: [Color(red: 0.03, green: 0.09, blue: 0.17),
                                                      Palette.bg],
                                             center: .init(x: 0.5, y: 0.4),
                                             startRadius: 10, endRadius: 420))
                )
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(Palette.line, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    Text("drag to move · tap to click · two fingers to scroll · hold to right-click")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                }
                .padding(.horizontal, 12)

            HStack(spacing: 10) {
                Key("CLICK") { link.click(.left) }
                Key("MIDDLE") { link.click(.middle) }
                Key("RIGHT") { link.click(.right) }
                Key(dragLock ? "DROP" : "DRAG", active: dragLock) {
                    dragLock.toggle()
                    link.press(.left, down: dragLock)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 10) {
                Key("\u{23EE}") { link.key("prev") }
                Key("\u{23EF}") { link.key("playpause") }
                Key("\u{23ED}") { link.key("next") }
                Key("\u{2212}") { link.key("volumedown") }
                Key("\u{FF0B}") { link.key("volumeup") }
                Key("\u{1F507}") { link.key("mute") }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 10) {
                Key("DASHBOARD") { link.command("mode", ["mode": "hud"]) }
                Key("ORB") { link.command("mode", ["mode": "desktop"]) }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TextField("type on the PC", text: $typed)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($typing)
                    .padding(12)
                    .background(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(Palette.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(Palette.ink)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        link.type(typed)
                        link.key("enter")
                        typed = ""
                        typing = true            // keep the keyboard up
                    }
                Key("\u{232B}") { link.key("backspace") }
                Key("\u{21B5}") {
                    if !typed.isEmpty { link.type(typed); typed = "" }
                    link.key("enter")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Palette.bg.ignoresSafeArea())
    }
}

struct Key: View {
    let title: String
    var active = false
    let action: () -> Void

    init(_ title: String, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .kerning(1.4)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .foregroundStyle(active ? Palette.bg : Palette.hot)
        .background(active ? Palette.hot : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hot, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - screen

struct ScreenTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Link
    @State private var live = false
    @State private var monitor = 0
    @State private var fps = 8.0

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()

            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let data = link.frame, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .onTapGesture(coordinateSpace: .local) { point in
                                tap(point, in: geo.size, image: img.size)
                            }
                    } else {
                        Text(live ? "waiting for a frame…" : "press LIVE")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                    }
                }
            }

            HStack(spacing: 10) {
                Picker("", selection: $monitor) {
                    ForEach(link.displays) { d in
                        Text(d.label).tag(d.index)
                    }
                }
                .pickerStyle(.menu)

                Picker("", selection: $fps) {
                    Text("4 fps").tag(4.0)
                    Text("8 fps").tag(8.0)
                    Text("15 fps").tag(15.0)
                    Text("24 fps").tag(24.0)
                }
                .pickerStyle(.menu)

                Key(live ? "STOP" : "LIVE", active: live) {
                    live.toggle()
                    push()
                }
                .frame(width: 96)
            }
            .padding(12)
            .background(Palette.bg)
        }
        .background(Palette.bg.ignoresSafeArea())
        .onChange(of: monitor) { _, _ in if live { push() } }
        .onChange(of: fps) { _, _ in if live { push() } }
        .onDisappear {
            // Leaving the tab stops the stream. Encoding JPEGs of three
            // monitors for a view nobody is looking at is a straight tax on the
            // machine Jarvis is trying to keep responsive.
            if live { live = false; push() }
        }
    }

    private func push() {
        link.command("screen", ["on": live, "monitor": monitor,
                                      "fps": Int(fps), "width": 1280,
                                      "quality": 55])
    }

    /// A tap on the picture is a click on the real pixel. The mapping goes
    /// through the display geometry the PC sent, so it is correct on a
    /// three-monitor desk where the union does not start at 0,0.
    private func tap(_ point: CGPoint, in view: CGSize, image: CGSize) {
        guard let d = link.displays.first(where: { $0.index == monitor })
        else { return }
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
}

// MARK: - the real HUD

struct HUDTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            if let url = model.hudURL {
                WebView(url: url)
            } else {
                Spacer()
                Text("not connected").foregroundStyle(Palette.dim)
                Spacer()
            }
        }
        .background(Palette.bg.ignoresSafeArea())
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The HUD plays sound and shows video in its panels; on iOS both need
        // saying explicitly or the first one silently does nothing.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        // The HUD is laid out for a 4442-pixel desktop. Letting it be pinched
        // and panned is the honest answer for a phone: it is the real thing,
        // and the real thing is wide.
        web.scrollView.minimumZoomScale = 0.15
        web.scrollView.maximumZoomScale = 4
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.url != url { web.load(URLRequest(url: url)) }
    }
}

// MARK: - talk

struct TalkTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var link: Link
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(link.transcript.enumerated()), id: \.offset) {
                            i, line in
                            Text(line)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(colour(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: link.transcript.count) { _, n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("ask him something", text: $text)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Palette.panel)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(Palette.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(Palette.ink)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(send)
                Key("SEND", action: send).frame(width: 90)
            }
            .padding(12)
        }
        .background(Palette.bg.ignoresSafeArea())
    }

    private func send() {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        link.command("ask", ["text": v])
        text = ""
    }

    private func colour(for line: String) -> Color {
        let l = line.lowercased()
        if l.hasPrefix("jarvis:") { return Palette.hot }
        if l.hasPrefix("you:") { return Palette.ink }
        return Palette.dim
    }
}
