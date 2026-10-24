# KVJ

Live VJ for DJs: KVJ listens to what the DJ is playing, recognizes which video of
the Set it belongs to and where, and projects that video in sync, with live words
and emoji over the picture. macOS and Windows.

- `core/recognize` — short-window acoustic landmark retrieval and verification.
- `core/engine` — Set document, indexing, native audio capture (Core Audio Tap,
  ScreenCaptureKit, WASAPI loopback), the following loop and a JSON C ABI
  (`core/engine/include/kvj.h`); `kvj-cli` drives it without a window.
- `app` — Qt 6 Quick shell: control window, projection window, system video
  decoding (VideoToolbox / Media Foundation) and the overlay.

## Two computers

The DJ's computer can run KVJ in **只发送** (`KVJ --send`): it captures the
Master, turns it into recognition features and streams them over classic
Bluetooth (RFCOMM) to the projecting computer. Nothing else runs there — no Set,
index or video — so it stays light next to the DJ software. The projecting
computer picks **蓝牙接收** as its input and chooses the current DJ among the
connected ones. Pair the two computers in the system's Bluetooth settings first.

## Load

Video is decoded and scaled by the system (VideoToolbox / Media Foundation with
D3D11), capped by the chosen resolution (default 720p) and frame rate (default
30). Three frames are held ahead and their buffers reused, the picture redraws
only when a new frame is due, and nothing is decoded while the output is put
away.

## Build

Needs Rust (stable), CMake ≥ 3.22, Ninja and Qt 6.8.

```sh
cargo test -p kvj-recognize -p kvj-engine
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build
cmake --install build --prefix dist   # bundles Qt next to the app
```

On Windows run these from a Visual Studio developer prompt.
