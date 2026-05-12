# ChromeCaster

macOS app that captures a **Google Chrome** window with **ScreenCaptureKit**, encodes **H.264 + AAC** with a bundled **FFmpeg** child process, and **publishes RTSP (TCP)** to **[MediaMTX](https://github.com/bluenviron/mediamtx)** on the same machine. You watch the stream on a TV or stick (e.g. Fire TV) with **VLC** using an `rtsp://…` URL.

```
Chrome (SCK) → NV12 scaler → FFmpeg (stdin rawvideo + optional audio FIFO)
       → H.264 (VideoToolbox) + AAC → RTSP publish → MediaMTX → VLC on LAN
```

## Requirements

- **macOS** with Xcode (project targets macOS 12.3+).
- **Google Chrome** with at least one on-screen window (used as the capture target).
- **Screen Recording** permission for ChromeCaster (System Settings → Privacy & Security → Screen Recording).
- **FFmpeg** on the build machine so the **Embed ffmpeg** build phase can copy a signed binary into the app (`brew install ffmpeg` is typical).
- **[MediaMTX](https://github.com/bluenviron/mediamtx)** installed and running **before** you press **Start** in the app (see below).

## Build

1. Open `ChromeCaster.xcodeproj` in Xcode.
2. Ensure a usable `ffmpeg` exists (e.g. `/opt/homebrew/bin/ffmpeg`); the **Embed ffmpeg** script copies it into `Contents/MacOS/ffmpeg` and fixes dylib paths for sandbox use.
3. **Product → Build** (Debug is fine).

## Run MediaMTX (required)

The app does **not** embed MediaMTX. FFmpeg connects to:

`rtsp://127.0.0.1:<port>/live`

Default **port is 8554** (configurable in the app as **RTSP port**).

1. Use the sample config in the repo:

   ```bash
   mediamtx /path/to/ChromeCaster/ChromeCaster/scripts/mediamtx.yml
   ```

   That config defines path **`live`** with `source: publisher`, which matches the app’s publish URL.

2. Leave MediaMTX running, then start **ChromeCaster** and press **Start**.

### “listen udp :8000: address already in use”

MediaMTX’s **default** full config may enable **WebRTC** or other listeners on **UDP 8000**. If something else already uses that port, either stop the other process or extend `scripts/mediamtx.yml` with settings from the upstream [`mediamtx.yml`](https://github.com/bluenviron/mediamtx/blob/main/mediamtx.yml) sample—for example disable WebRTC or change conflicting addresses—then restart MediaMTX.

## Run ChromeCaster

1. Open Chrome to the content you want to cast.
2. Start MediaMTX with `scripts/mediamtx.yml` (port **8554** unless you changed it).
3. Launch **ChromeCaster**, set **RTSP port** to match MediaMTX (default **8554**).
4. Press **Start**. The app shows an **RTSP URL** using your Mac’s **LAN IPv4** (e.g. `rtsp://192.168.1.5:8554/live`).
5. On the TV device, **VLC → Open Network Stream** and paste that URL.

**Optional (lower VLC buffering):**  
`rtsp://192.168.1.5:8554/live :network-caching=100`

### Audio

- With **tab audio** enabled (macOS 13+ when SCK provides it), Chrome **still plays audio on the Mac**; mute the tab or use headphones if you do not want double playback.
- The **Stream audio level** slider scales PCM sent into the stream only (not the Mac’s local Chrome output).

### Audio-only mode

Captures **tab audio** only (black video encoded). Chrome must still have a window for filtering; macOS 13+ required for this path.

## Firewall

Allow incoming **TCP** on the **MediaMTX RTSP port** (default **8554**) from your LAN so the TV can connect. The app connects **outbound** to `127.0.0.1` for publishing; the TV connects **inbound** to MediaMTX on the Mac.

## Project layout (high level)

| Path | Role |
|------|------|
| `ChromeCaster/FFmpegStreamer.swift` | Spawns FFmpeg, rawvideo stdin, optional FIFO audio, RTSP output URL, stdin mailbox for low latency |
| `ChromeCaster/WindowCaptureManager.swift` | SCK stream for Chrome window + optional audio |
| `ChromeCaster/PixelBufferConverter.swift` | NV12 resize to 960×540 (default), packed frames for FFmpeg |
| `ChromeCaster/SessionManager.swift` | SwiftUI session lifecycle, VLC URL string |
| `ChromeCaster/scripts/embed-ffmpeg.sh` | Xcode run script: embed and re-sign `ffmpeg` + dylibs |
| `ChromeCaster/scripts/mediamtx.yml` | Minimal MediaMTX path `live` / `publisher` |

## Troubleshooting

| Symptom | Things to check |
|--------|-------------------|
| FFmpeg exits immediately | MediaMTX not running, wrong port, or Console `[ffmpeg]` / `[FFmpegStreamer]` logs |
| No video after first frame | Usually stdin/publish pipeline; check Console for conversion or RTSP errors |
| No audio on TV | Tab audio not attached (permission / macOS), or AAC/interleave—avoid changing audio-related FFmpeg flags without retesting (see comments in `FFmpegStreamer.swift`) |
| `ffmpeg not found` on build | Install FFmpeg and clean build so **Embed ffmpeg** runs |

## License

Add your preferred license here if the repository is public.
