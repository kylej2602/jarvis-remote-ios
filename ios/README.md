# Jarvis on the phone

The whole of Jarvis, from an iPhone, over Wi-Fi: his real HUD, every tool he
has, your screen, and this PC's own mouse and keyboard.

---

## What you get

| Tab | What it is |
|---|---|
| **Control** | A trackpad that moves the real Windows pointer, click/right-click/middle, a drag lock, media and volume keys, dashboard/orb, and a field that types on the PC. |
| **Screen** | Live JPEG of any monitor (or all three at once). Tap the picture and the real pointer goes to that real pixel and clicks. |
| **HUD** | The actual `index.html` — the same file the desktop loads, served from the PC, with `js/remote-bridge.js` standing in for WebView2. Not a phone version of the HUD. The HUD. |
| **Talk** | The live transcript, mirrored from Jarvis's own `ui_call`, and a box to ask him something. It goes through the identical code path as speaking out loud. |

The latency is shown in the top-right of every tab, always, because "quick by
the millisecond" is a claim that should be checkable. On a 5 GHz network expect
**2–5 ms**; on Ethernet-to-PC, under 1 ms.

---

## Turn it on, on the PC

In `.env`:

```
JARVIS_REMOTE=1
```

Restart Jarvis. He logs the address:

```
[remote] phone control on http://192.168.1.10:8765 - say "pair my phone" for a code.
```

Windows Firewall will ask the first time. Allow it on **private** networks only.

---

## Pair

1. Say **"Jarvis, pair my phone."** He reads out six digits, good for two
   minutes and for one device.
2. Open the app. It sweeps the network and lists whatever it finds; tap your PC.
3. Type the six digits.

That's it — the key is kept in the iPhone Keychain and it reconnects by itself
from then on, including after the phone has been asleep, changed network or
been out of range.

**"Jarvis, forget my phones"** revokes every device and changes the key.

### No app? No problem

Open `http://192.168.1.10:8765` in Safari. `phone.html` is the same control
surface in a web page — trackpad, screen, transcript, the lot — and pairs the
same way. The app exists because a web page cannot get raw touch samples at
240 Hz or turn Nagle off, which is most of the difference in how the trackpad
feels.

---

## Getting the .ipa

You need a Mac to compile an iOS app, and this is built on Windows. GitHub's
macOS runners are the way round that.

1. Push this repository to GitHub.
2. **Actions → "iPhone app" → Run workflow.** (It also runs on any push that
   touches `ios/`.)
3. When it finishes: **Artifacts → Jarvis-ipa**. Unzip; `Jarvis.ipa` is inside.

The `.ipa` is **unsigned**, deliberately — sideloading tools sign it themselves,
with the Apple ID already on your machine, and re-sign it when the certificate
rolls over.

4. **[Sideloadly](https://sideloadly.io)** on Windows: drag `Jarvis.ipa` in,
   enter your Apple ID, press Start.
5. On the phone: **Settings → General → VPN & Device Management** → trust the
   developer.

A free Apple ID gives seven days before it needs re-signing. A paid developer
account gives a year, and lets you install on more devices.

### If you have a Mac

```sh
brew install xcodegen
cd ios && xcodegen && open Jarvis.xcodeproj
```

Plug the phone in, pick it as the destination, press run.

---

## From outside the house

Don't forward the port. Put the PC on [Tailscale](https://tailscale.com),
install it on the phone too, and type the Tailscale address into the app's
manual field. Everything works unchanged — it is only a socket — and it is
encrypted end to end instead of being on the open internet.

---

## How it is put together

```
phone                          PC
─────                          ──
Link.swift                     remote.py
  NWConnection                   ThreadingHTTPServer
  + NWProtocolWebSocket          + RFC 6455 by hand
  + tcp.noDelay = true           + TCP_NODELAY
        │                              │
        ├── 9-byte binary frames ─────►│  _Pointer coalescer ──► SendInput
        ├── JSON commands ────────────►│  the same tools the voice uses
        │◄── JSON telemetry ───────────┤  mirrored from main.ui_call
        │◄── JPEG screen frames ───────┤  mss + cv2
        │
WKWebView ──── http://pc/hud ─────────►│  index.html + js/remote-bridge.js
```

Three decisions are worth knowing about, because they are the ones that would
be tempting to undo:

**One socket, kept open.** A POST per pointer move would pay a TCP handshake
and a header block per movement — roughly forty times the bytes of the movement
itself, and three round trips before the pointer hears about it.

**`tcp.noDelay` on both ends.** Nagle's algorithm holds small writes back until
they have company. A moving finger is nothing but small writes. Without this
the same frame took 15–45 ms instead of 2–4, and you could see it.

**Coalescing, not replaying.** `event.coalescedTouches` gives every sample the
digitiser took — 240 Hz on a modern iPhone — and they are summed into one move
rather than sent as forty. `remote.py` sums again before it injects. The
pointer therefore ends up where your finger *is*, rather than tracing where it
was a fifth of a second ago.

`tests/test_remote.py` drives the whole PC side over a real socket: pairing,
framing, masking, every input opcode, the coalescer, the latency echo and the
HUD with its shim.
