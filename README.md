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

## One window

Everything is in one window. The sidebar holds the Sets and the selected Set's
entries; each entry has a switch that decides whether it is followed, and it
works during the show too: at a handover between DJs the next DJ's entries are
turned on while the last ones stay on, and the last are turned off once the next
set is under way. Every entry is indexed either way, so switching never waits
for indexing; turning off the entry on the screen keeps the picture until
another entry is found. The middle is the live desk, the right side follows and
projects, or only sends.

The **timeline** under the desk has a lane per entry that is on: the one on the
screen with a playhead carried on the engine's clock, the others holding where
they were last seen. Beside it the speed the music runs at against the recording
(×1.025, +2.5 %), whether that speed has settled, and its trace over the last
minute.

## Live desk

The live desk is a light preview of the
projection, danmaku (Enter sends; scrolling or large in the middle), Google
Meet–style reactions (Noto's animated emoji rising up the sides; hold to send a
stream), stickers and picture effects. Stickers are kept in a gallery of images
and words; the preview doubles as the stage, where a dot marks where the
selected one goes and a slider sets its size, and it is drawn there as it will
look before it is posted. Each effect (mosaic, RGB split, video wall, lens, zoom
blur, wave, glitch, scanlines, halftone, posterize, hue, black and white,
vignette) is on and at 0 until its slider moves; effects touch only the video,
never the words or stickers. Danmaku from elsewhere can come in through
`Live.say(text, from)` (`app/qml/Live.qml`).

## Load

Video is decoded and scaled by the system (VideoToolbox / Media Foundation with
D3D11), capped by the chosen resolution (default 720p) and frame rate (default
30). Three frames are held ahead and their buffers reused, the picture redraws
only when a new frame is due, and nothing is decoded while neither the output nor
the preview is up. The preview decodes nothing of its own: it takes a reduced
copy of the projected frame about 12 times a second, and its overlay moves on a
12 Hz clock. With every effect at 0 the picture is drawn without the effect pass.

## Build

Needs Rust (stable), CMake ≥ 3.22, Ninja and Qt 6.8 with Qt Shader Tools and Qt
Image Formats.

```sh
cargo test -p kvj-recognize -p kvj-engine
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build
cmake --install build --prefix dist   # bundles Qt next to the app
```

On Windows run these from a Visual Studio developer prompt.
