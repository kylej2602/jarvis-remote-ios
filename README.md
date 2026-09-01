# Jarvis Remote — iPhone

Control a Jarvis PC from an iPhone over Wi-Fi: his real HUD, every tool he has,
your screen, and the machine's own mouse and keyboard.

**Round trip: 2–5 ms on Wi-Fi.** The number is shown in the app, on every
screen, because "fast" is a claim that should be checkable.

---

## Install it (Scarlet, no computer needed)

1. Open **Scarlet** on the phone → **+** → **from URL**
2. Paste:

   ```
   https://github.com/OWNER/REPO/releases/latest/download/Jarvis.ipa
   ```

3. Let it sign and install.

That link always points at the newest build, so it never has to change. If
Scarlet's certificate is revoked, re-install from the same URL.

> The `.ipa` is **unsigned on purpose** — Scarlet, Sideloadly and AltStore all
> sign on the way onto the device with the identity already there, and re-sign
> when it rolls over. Shipping it pre-signed would tie every build to one
> certificate and one provisioning profile.

**Sideloadly / AltStore on a computer** work the same way: download the `.ipa`
from [Releases](../../releases/latest), drag it in, enter your Apple ID.

---

## Turn the PC on

In the Jarvis `.env`:

```
JARVIS_REMOTE=1
```

Restart him. He logs the address:

```
[remote] phone control on http://192.168.1.10:8765 - say "pair my phone" for a code.
```

Allow it through Windows Firewall on **private** networks only.

## Pair

1. Say **"Jarvis, pair my phone."** He reads out six digits — good for two
   minutes and for one device.
2. Open the app. It sweeps the network and lists what it finds; tap your PC.
   (Or type the address it logged.)
3. Type the six digits.

The key goes in the iPhone Keychain and it reconnects by itself from then on —
after sleep, after changing network, after being out of range.

**"Jarvis, forget my phones"** revokes every device and changes the key.

---

## What's in it

| Tab | |
|---|---|
| **Control** | Trackpad driving the real Windows pointer. Tap to click, two fingers to scroll, hold for right-click, drag lock, media and volume keys, dashboard/orb, and a field that types on the PC. |
| **Screen** | Live JPEG of any monitor or all of them at once. Tap the picture and the real pointer goes to that real pixel and clicks. |
| **HUD** | The actual `index.html` — the same file the desktop loads, served from the PC. Not a phone version of the HUD. The HUD. |
| **Talk** | The live transcript, mirrored from Jarvis's own `ui_call`, and a box to ask him things — the identical code path as speaking out loud. |

No app? Open `http://<pc>:8765` in Safari. The PC serves the same control
surface as a web page and it pairs the same way.

---

## Building it yourself

The `.ipa` is built by GitHub Actions on a macOS runner — **Actions → "iPhone
app" → Run workflow** — and published to Releases. It also runs on any push
touching `ios/`.

With a Mac:

```sh
brew install xcodegen
cd ios && xcodegen && open Jarvis.xcodeproj
```

There is no `.xcodeproj` in the repository on purpose: `ios/project.yml` *is*
the project, and a `pbxproj` is 900 lines of generated XML with UUID
cross-references that conflicts on every change and nobody can review.

---

## How it works

```
phone                          PC
─────                          ──
Link.swift                     remote.py
  NWConnection                   ThreadingHTTPServer
  + NWProtocolWebSocket          + RFC 6455 by hand
  + tcp.noDelay = true           + TCP_NODELAY
        │                              │
        ├── 9-byte binary frames ─────►│  coalescer ──► SendInput
        ├── JSON commands ────────────►│  the same tools the voice uses
        │◄── JSON telemetry ───────────┤  mirrored from main.ui_call
        │◄── JPEG screen frames ───────┤  mss + OpenCV
        │
WKWebView ──── http://pc/hud ─────────►│  index.html + js/remote-bridge.js
```

Three decisions carry the latency, and all three would be tempting to undo:

**One socket, kept open.** A POST per pointer move pays a TCP handshake and a
header block per movement — roughly forty times the bytes of the movement
itself, and three round trips before the pointer hears about it.

**`tcp.noDelay` on both ends.** Nagle's algorithm holds small writes back until
they have company. A moving finger is nothing but small writes. Without it the
same frame took 15–45 ms instead of 2–4, and you could see it.

**Coalescing, not replaying.** `event.coalescedTouches` hands over every sample
the digitiser took — 240 Hz on a modern iPhone — and they are summed into one
move rather than sent as forty. The PC sums again before injecting. So the
pointer ends up where your finger *is*, instead of tracing where it was a fifth
of a second ago.

## Security

It is on your LAN by definition — a phone cannot reach a loopback address — so:

- a 32-byte token, generated once, kept in the PC's data folder; **every**
  request carries it, HTTP and WebSocket alike;
- pairing is a spoken six-digit code, valid two minutes, one device;
- the pairing page and `/api/hello` are the only unauthenticated endpoints and
  neither returns anything useful;
- it binds the LAN address and refuses to start on a public one.

**Do not port-forward it.** For access from outside the house, put the PC on
[Tailscale](https://tailscale.com) and use that address — it works unchanged,
because it is only a socket, and it is encrypted end to end.
