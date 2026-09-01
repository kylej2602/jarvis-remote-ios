//
//  Trackpad.swift - the surface that moves the PC's pointer.
//
//  THIS IS A RAW UIView AND NOT A GESTURE RECOGNISER, AND THAT IS THE POINT.
//  UIPanGestureRecognizer has to decide whether a touch is a pan before it will
//  tell you about it, and "decide" means waiting - typically a frame or two,
//  and longer when there is a competing recogniser in the hierarchy. On a
//  trackpad that delay is the difference between the pointer feeling attached
//  to your finger and feeling like it is being dragged behind it. touchesMoved
//  is delivered with no such deliberation.
//
//  Two more things matter for latency, and both are one line:
//
//    * event.coalescedTouches(for:) returns EVERY sample the digitiser took
//      since the last delivery, not just the latest one. On a 120 Hz phone the
//      touch hardware runs at 240 Hz, so half the movement is in there. Summing
//      them means the pointer travels the true distance rather than the sampled
//      distance - without it, fast swipes come up short and the whole thing
//      feels slow in a way that no sensitivity setting fixes.
//
//    * one send per delivery, not one per sample. The frames are summed and
//      sent as a single nine-byte move; remote.py sums again on the other side
//      before it injects. See the coalescer there.
//
//  The gestures themselves are the ones a MacBook trackpad has, because those
//  are the ones already in his fingers: drag to move, tap to click, two fingers
//  to scroll, press and hold for a right click.
//

import SwiftUI
import UIKit

struct Trackpad: UIViewRepresentable {
    let link: Link
    /// Multiplies the raw finger movement. Windows applies its own pointer
    /// acceleration on top, which is what lets a small pad cross three
    /// monitors without a huge multiplier here.
    var sensitivity: CGFloat = 1.7

    func makeUIView(context: Context) -> TrackpadView {
        let v = TrackpadView()
        v.link = link
        v.sensitivity = sensitivity
        return v
    }

    func updateUIView(_ v: TrackpadView, context: Context) {
        v.link = link
        v.sensitivity = sensitivity
    }
}

final class TrackpadView: UIView {

    var link: Link?
    var sensitivity: CGFloat = 1.7

    private var lastPoint: CGPoint?
    private var travelled: CGFloat = 0
    private var startedAt: CFAbsoluteTime = 0
    private var twoFinger = false
    private var holdWork: DispatchWorkItem?
    private var consumed = false            // a hold already fired; ignore the tap
    private var dragging = false            // tap-then-drag has the button down

    private let tapWindow: CFAbsoluteTime = 0.22
    private let tapSlop: CGFloat = 10
    private let holdDelay: TimeInterval = 0.52
    private let scrollDivisor: CGFloat = 26

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        twoFinger = (event?.allTouches?.count ?? 1) > 1
        lastPoint = t.location(in: self)
        travelled = 0
        startedAt = CFAbsoluteTimeGetCurrent()
        consumed = false

        holdWork?.cancel()
        guard !twoFinger else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.travelled < self.tapSlop else { return }
            self.consumed = true
            Task { @MainActor in self.link?.click(.right) }
            // A haptic tick, so a right click does not have to be watched for.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, var last = lastPoint else { return }

        // Every sample the digitiser took since the last delivery, not just the
        // one UIKit chose to hand over. See the header.
        let samples = event?.coalescedTouches(for: t) ?? [t]
        var dx: CGFloat = 0, dy: CGFloat = 0
        for s in samples {
            let p = s.location(in: self)
            dx += p.x - last.x
            dy += p.y - last.y
            last = p
        }
        lastPoint = last
        travelled += abs(dx) + abs(dy)

        let fingers = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 1

        if fingers > 1 {
            twoFinger = true
            holdWork?.cancel()
            // Natural scrolling: pushing the content up scrolls down, which is
            // what every other surface on the phone does.
            Task { @MainActor in
                link?.move(dx: 0, dy: 0,
                           wheel: Double(-dy / scrollDivisor),
                           hwheel: Double(dx / scrollDivisor))
            }
        } else {
            if travelled >= tapSlop { holdWork?.cancel() }
            Task { @MainActor in
                link?.move(dx: Int((dx * sensitivity).rounded()),
                           dy: Int((dy * sensitivity).rounded()))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdWork?.cancel()
        let quick = CFAbsoluteTimeGetCurrent() - startedAt < tapWindow
        let still = travelled < tapSlop
        if !consumed && !twoFinger && quick && still {
            Task { @MainActor in link?.click(.left) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if dragging {
            dragging = false
            Task { @MainActor in link?.press(.left, down: false) }
        }
        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        holdWork?.cancel()
        if dragging {
            dragging = false
            Task { @MainActor in link?.press(.left, down: false) }
        }
        reset()
    }

    private func reset() {
        lastPoint = nil
        travelled = 0
        twoFinger = false
        consumed = false
    }

    /// Called by the "drag lock" button: holds the left button down so a window
    /// can be moved without needing a second finger on a phone screen.
    @MainActor
    func setDragLock(_ on: Bool) {
        dragging = on
        link?.press(.left, down: on)
    }
}
