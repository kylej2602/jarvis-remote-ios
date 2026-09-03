//
//  Pointer.swift - the PC's mouse, drawn on the phone.
//
//  Windows does not composite the cursor into a framebuffer grab, so every
//  frame that arrives from remote.capture_jpeg has no pointer in it. Watching
//  the PC from the sofa was therefore a guessing game: you drag, something
//  scrolls, and you have no idea what you are about to click.
//
//  It is drawn here instead of being burned into the JPEG, for three reasons.
//  The video runs at four to eight frames a second to fit down a phone uplink,
//  and a pointer that only moves eight times a second reads as broken however
//  well it is drawn. A vector glyph stays sharp when the picture is pinch-
//  zoomed or shown full screen, where a scaled-down 32-pixel bitmap turns to
//  mush. And the position arrives on its own eleven-byte packet thirty times a
//  second - about 330 bytes a second, a thousandth of one JPEG frame - so the
//  pointer is smooth even when the picture underneath it is not.
//
//  See remote._cursor_loop for the sending half and Link.handleBinary for the
//  decode.
//
import SwiftUI

/// Where the picture actually sits inside the view it was given.
///
/// `.aspectRatio(contentMode: .fit)` letterboxes, so the image is smaller than
/// its container and offset by the bars. Every mapping between a screen pixel
/// and a point on this phone goes through here - the pointer overlay, the tap
/// that clicks, and the drag that moves - which is what stops them disagreeing
/// with each other by half a letterbox.
struct ShownImage {
    let origin: CGPoint
    let size: CGSize

    init(view: CGSize, image: CGSize) {
        guard image.width > 0, image.height > 0 else {
            origin = .zero
            size = view
            return
        }
        let scale = min(view.width / image.width, view.height / image.height)
        size = CGSize(width: image.width * scale, height: image.height * scale)
        origin = CGPoint(x: (view.width - size.width) / 2,
                         y: (view.height - size.height) / 2)
    }

    /// A virtual-desktop pixel, as a point in this view. Nil if the display is
    /// unknown; the fraction is NOT clamped, so callers can tell whether the
    /// pointer is on this monitor at all.
    func place(_ x: Int, _ y: Int, on d: Display) -> (point: CGPoint, onScreen: Bool) {
        let fx = CGFloat(x - d.x) / CGFloat(max(1, d.w))
        let fy = CGFloat(y - d.y) / CGFloat(max(1, d.h))
        let on = (0...1).contains(fx) && (0...1).contains(fy)
        let cx = min(max(fx, 0), 1), cy = min(max(fy, 0), 1)
        return (CGPoint(x: origin.x + cx * size.width,
                        y: origin.y + cy * size.height), on)
    }
}

/// The pointer itself: a glyph saying what it is, over a halo saying where.
///
/// The halo is the part that matters from across a room. A 24-point arrow on a
/// 6.1-inch screen showing a 3200-pixel desktop is small, and the eye cannot
/// find it against a busy page; a breathing cyan ring can be found instantly
/// and then the glyph tells you what you are hovering over.
struct PointerOverlay: View {
    let cursor: CursorState
    let display: Display?
    let shown: ShownImage

    @State private var breathing = false

    var body: some View {
        if cursor.seen, cursor.visible, let d = display {
            let placed = shown.place(cursor.x, cursor.y, on: d)
            ZStack {
                Circle()
                    .stroke(Palette.hot,
                            style: StrokeStyle(lineWidth: 2,
                                               dash: placed.onScreen ? [] : [4, 3]))
                    .background(Circle().fill(Palette.hot.opacity(0.13)))
                    .frame(width: 34, height: 34)
                    .shadow(color: Palette.hot.opacity(0.8), radius: 7)
                    .scaleEffect(breathing ? 1.16 : 1.0)
                    .opacity(breathing ? 0.55 : 0.9)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                               value: breathing)

                CursorGlyph(kind: cursor.kind)
                    .frame(width: 26, height: 26)
                    // The hot-spot of a real arrow is its tip, not its middle,
                    // so the glyph is nudged down and right to sit under the
                    // ring the way the Windows cursor sits under the mouse.
                    .offset(x: 9, y: 9)
                    .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            }
            // Off this monitor entirely - the pointer is on another screen.
            // Pinned to the edge it left by and faded rather than hidden,
            // because vanishing reads as a bug and this reads as a direction.
            .opacity(placed.onScreen ? 1 : 0.4)
            .position(placed.point)
            .allowsHitTesting(false)
            .onAppear { breathing = true }
            // No animation on the position: it already arrives thirty times a
            // second, and interpolating on top of that only adds lag.
            .animation(nil, value: cursor.x)
            .animation(nil, value: cursor.y)
        }
    }
}

/// White with a heavy dark outline, because it has to read against a white
/// document and against a dark game in the same second.
struct CursorGlyph: View {
    let kind: CursorKind

    var body: some View {
        switch kind {
        case .ibeam:
            shape(Shapes.ibeam)
        case .hand:
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
        case .wait, .busy:
            Image(systemName: "hourglass")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Palette.warm)
                .shadow(color: .black, radius: 1)
        case .no:
            Image(systemName: "nosign")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Palette.bad)
                .shadow(color: .black, radius: 1)
        case .size:
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
        case .cross:
            shape(Shapes.cross)
        case .arrow, .help:
            shape(Shapes.arrow)
        }
    }

    private func shape(_ path: @escaping (CGRect) -> Path) -> some View {
        ZStack {
            // The outline is drawn first and thicker, so the white glyph sits
            // in a dark keyline and stays visible on a white document.
            PathShape(path).stroke(Color(white: 0.03),
                                   style: StrokeStyle(lineWidth: 3.4,
                                                      lineJoin: .round))
            PathShape(path).fill(.white)
        }
    }
}

private struct PathShape: Shape {
    let make: (CGRect) -> Path
    init(_ make: @escaping (CGRect) -> Path) { self.make = make }
    func path(in rect: CGRect) -> Path { make(rect) }
}

private enum Shapes {
    /// The ordinary arrow, drawn to the same proportions as the Windows one so
    /// it is recognisable rather than merely present.
    static func arrow(_ r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 4 * u, y: 2 * u))
        p.addLine(to: CGPoint(x: 4 * u, y: 19 * u))
        p.addLine(to: CGPoint(x: 8.6 * u, y: 14.8 * u))
        p.addLine(to: CGPoint(x: 11.4 * u, y: 21 * u))
        p.addLine(to: CGPoint(x: 14.4 * u, y: 19.6 * u))
        p.addLine(to: CGPoint(x: 11.6 * u, y: 13.6 * u))
        p.addLine(to: CGPoint(x: 18 * u, y: 13.2 * u))
        p.closeSubpath()
        return p
    }

    static func ibeam(_ r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 8 * u, y: 3 * u))
        p.addLine(to: CGPoint(x: 16 * u, y: 3 * u))
        p.move(to: CGPoint(x: 12 * u, y: 3 * u))
        p.addLine(to: CGPoint(x: 12 * u, y: 21 * u))
        p.move(to: CGPoint(x: 8 * u, y: 21 * u))
        p.addLine(to: CGPoint(x: 16 * u, y: 21 * u))
        return p.strokedPath(StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
    }

    static func cross(_ r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        var p = Path()
        p.move(to: CGPoint(x: 12 * u, y: 3 * u))
        p.addLine(to: CGPoint(x: 12 * u, y: 21 * u))
        p.move(to: CGPoint(x: 3 * u, y: 12 * u))
        p.addLine(to: CGPoint(x: 21 * u, y: 12 * u))
        return p.strokedPath(StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
    }
}

/// A ring that leaves, at the point that was clicked.
///
/// Worth the twenty lines: over a link with a hundred milliseconds of latency
/// there is otherwise no way to tell a click that landed from a click the page
/// was too busy to take, and the natural response to that uncertainty is to
/// tap again - which is how a remote single click becomes a double click on
/// something that did not want one.
struct ClickPing: View, Identifiable {
    let id = UUID()
    let at: CGPoint
    let button: MouseButton

    @State private var out = false

    var body: some View {
        Circle()
            .stroke(button == .right ? Palette.warm : .white, lineWidth: 2.5)
            .frame(width: 26, height: 26)
            .scaleEffect(out ? 2.7 : 0.3)
            .opacity(out ? 0 : 1)
            .position(at)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { out = true }
            }
    }
}
