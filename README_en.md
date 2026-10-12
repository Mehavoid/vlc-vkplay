[Русский](README.md) | **English**

# VLC-VKPlay
A VLC playlist parser for watching [VK Video Live](https://live.vkvideo.ru/) streams and recordings.

## Installation
1. Download the file for your VLC from the [Releases](../../releases) page:

| VLC | File |
|---|---|
| VLC 3.x, Windows (x64) | `vkplay-windows.luac` |
| VLC 3.x, macOS | `vkplay-macos.luac` |
| VLC 3.x, Linux (Debian/Ubuntu packages) | `vkplay-linux.luac` |
| VLC 4.x, any OS | `vkplay-vlc4.luac` |
| Flatpak / Snap / anything else | `vkplay.lua` (source, works everywhere) |

2. Put it into the playlist scripts directory (create it if missing) and restart VLC:

| OS | Directory |
|---|---|
| Windows | `%APPDATA%\vlc\lua\playlist\` |
| macOS | `~/Library/Application Support/org.videolan.vlc/lua/playlist/` |
| Linux | `~/.local/share/vlc/lua/playlist/` |

Checksums: `sha256sum -c SHA256SUMS`.

## Usage
1. Copy the [URL](#faq) of a channel or a recording.
2. Open the dialog: `Media → Open Network Stream...`
3. Paste the URL and click `Play`.

## F.A.Q
- **What URLs are supported?**
```
https://live.vkvideo.ru/maddyson
https://live.vkvideo.ru/maddyson?share=stream_link
https://live.vkvideo.ru/maddyson/record/eaacfda0-2432-4e81-8107-cb34358d3789?share=stream_link
```
- **Which quality do recordings open in?** The highest available (up to 1440p). Recordings
  are played via HLS, so they start almost instantly even for multi-hour streams.
  For a single MP4 file instead, change `local RECORD_FORMAT = "hls"` to `"mp4"` at the top
  of `vkplay.lua`.
- **The VLC window resizes when seeking.** This is a VLC setting, not the plugin:
  `Tools → Preferences → Interface → uncheck "Resize interface to video size"`.
- **An "Insecure site" dialog appears.** Update the plugin: it bundles the CDN root
  certificates itself (see [CDN certificates](#cdn-certificates)). The VLC log should contain
  `loaded N trusted CAs from ...\vkplay-certs`.

## Building
- Windows 10/11 (Visual Studio 2022 Build Tools):  
  `powershell -ExecutionPolicy Bypass -File scripts\build.ps1` → `dist\`  
  add `-Publish -Tag <version>` to create a GitHub Release via `gh`.
- Linux / macOS: `scripts/build.sh <lua-version> <suffix>`, e.g. `scripts/build.sh 5.2.4 linux`.
- For Lua 5.1 (`windows`/`macos` targets) the scripts apply the VLC patch
  `scripts/patches/vlc3-luac-32bits.patch`: VLC 3.x stores sizes in bytecode as 32-bit, and a stock
  `luac` 5.1 produces a file VLC rejects with `bad header in precompiled chunk`.
- CI: pushing a tag builds all files and publishes a Release.

## CDN certificates
The plugin bundles the root CAs of the VK Video Live CDN (`TRUST_PEM` in `src/vkplay.lua`)
and passes them to VLC via `gnutls-dir-trust` **only for the streams it opens** — the system
trust store and other applications are not affected.

Bundled roots:
- **HARICA TLS ECC Root CA 2021** / **HARICA ECC RootCA 2015** — current
  `*.okcdn.ru` / `*.vkuser.net` chain (Mozilla store).
- **Russian Trusted Root CA** (Ministry of Digital Development, `certs/extra/`), SHA-256
  `D26D2D0231B7C39F92CC738512BA54103519E4405D68B5BD703E9788CA8ECF31`, valid until 2032-02-27.
  Not in public root programs; bundled in case the CDN moves to it.

`.github/workflows/cert-watch.yml` runs weekly: it resolves the CDN hosts through the VK API
(links in `scripts/cdn-probe.json`), verifies each host against the runner's Mozilla store plus
`certs/extra/`, and opens a pull request if a host chains to a Mozilla root that is not bundled.
Roots are never taken from what the server sends. Review the PR, then tag a release.

Manually vetted roots (not in the Mozilla store) are added only by hand, after checking the
fingerprint against the official source:

    python scripts/cert_watch.py --add-root russian_trusted_root_ca.cer --name russian-trusted-root-ca

- If VK/CDN do not answer GitHub runners, set the repository variable
  `CERT_WATCH_RUNNER=self-hosted` and use a runner without TLS inspection.
- Enable *Settings → Actions → General → Allow GitHub Actions to create pull requests*.

## References
- [Lua docs](https://www.lua.org/manual/5.4/)
- [VLC Lua extensions docs](https://github.com/videolan/vlc/blob/e8f0b72538c90bfc630c1c926a88990daaf9b448/share/lua/README.txt)
