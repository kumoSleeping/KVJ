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

## Build

Needs Rust (stable), CMake ≥ 3.22, Ninja and Qt 6.8.

```sh
cargo test -p kvj-recognize -p kvj-engine
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build
cmake --install build --prefix dist   # bundles Qt next to the app
```

On Windows run these from a Visual Studio developer prompt.
