<div align="center">
  <h1>
    Kumo's<br>
    <em>Video Jockey</em>
  </h1>

  <p>
    <img src="https://img.shields.io/badge/license-GPL--3.0--or--later-lightgrey?style=flat-square" alt="License">
    <a href="https://github.com/kumoSleeping/KVJ/releases"><img src="https://img.shields.io/github/v/release/kumoSleeping/KVJ?include_prereleases&style=flat-square&label=release&color=orange" alt="Release"></a>
    <img src="https://img.shields.io/badge/Rust-dea584?style=flat-square&logo=rust&logoColor=black" alt="Rust">
    <img src="https://img.shields.io/badge/Qt_6-41CD52?style=flat-square&logo=qt&logoColor=white" alt="Qt 6">
    <img src="https://img.shields.io/badge/C++-00599C?style=flat-square&logo=cplusplus&logoColor=white" alt="C++">
  </p>

  <br>

  <img src="docs/readme-assets/01-desk.webp" alt="KVJ main window" width="920">
</div>

---

[中文](README.md) · **English**

KVJ is live VJ software for DJs. It is a video player first: pick an entry, play, pause, jump anywhere and set the speed by hand. It is a smart player second: smart following (**音频对位**) listens to what the DJ is playing, recognizes which video of the Set it belongs to and where, and plays that video in sync, jumping and changing speed with the music. Danmaku, reactions and stickers go over the picture. macOS and Windows.

## Download & install

This is a preview (pre-release) build; every version is listed under [Releases](https://github.com/kumoSleeping/KVJ/releases).

<!-- release-package-size-badges:start -->
<p>
  <a href="https://github.com/kumoSleeping/KVJ/releases/download/v0.1.0-rc1/KVJ-macos-arm64.dmg"><img src="https://img.shields.io/badge/macOS_Apple_Silicon-24.2_MB-black?style=for-the-badge&logo=apple&logoColor=white" alt="macOS Apple Silicon 24.2 MB"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases/download/v0.1.0-rc1/KVJ-windows-x64.zip"><img src="https://img.shields.io/badge/Windows_x64-73.0_MB-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows x64 73.0 MB"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases"><img src="https://img.shields.io/badge/More-Releases-555555?style=for-the-badge&logo=github&logoColor=white" alt="More releases"></a>
</p>
<!-- release-package-size-badges:end -->

- **macOS**: open the DMG and drag KVJ into Applications. The app is not notarized; if macOS blocks the first launch, allow it under System Settings → Privacy & Security. Capturing system sound needs macOS 14.2 or later (screen-recording capture from 12.3); allow the microphone or system audio recording when KVJ first listens.
- **Windows**: unzip and run `bin\KVJ.exe`. If Windows reports a missing runtime, run `vc_redist.x64.exe` from the same folder first.

> [!NOTE]
> Video is decoded by the system (VideoToolbox on macOS, Media Foundation on Windows), so no FFmpeg is needed. Entries can be mp4, m4v, mkv, mov and webm.

## Features

### Player

- The sidebar is one tree of the Sets: each Set lists its entries grouped by the folders they came from; files and folders dropped on a Set go into it.
- Every entry has a switch that takes effect at once, also during a show: an entry that is off leaves the timeline and is not followed, while the picture on the screen goes on.
- A video-editor-style timeline runs across the foot: the whole Set as frame strips over KDJ's whole-track preview waveform, with pinch zoom, two-finger swipes and **全览** (overview).
- Pressing the timeline only moves the cursor; **跳至光标处** or Enter plays from it. Every jump can dissolve over 0.1–2 s.
- Speed goes from −50 % to +50 %; nudge keys bend the picture like a pitch bend (0.7× / 1.5× while held), and the arrow keys change the speed by 1 %.
- **播放声音** plays the entry's own sound on an output of its own, stretched by Rubber Band with its pitch kept, so speed changes and nudges never break it.
- The output picks the screen, resolution and frame rate; **推荐** chooses them from the screen and the video.

### Smart following

- Captures the Master, the system's sound or a microphone, and recognizes by acoustic landmarks which entry is playing and where.
- **对速** keeps the picture's speed with the music and **跳转监测** jumps to where the music is once the picture drifts past the threshold; each pauses on its own and hands its part back to the player.
- The whole Set is indexed ahead (about 0.6 MiB a minute, some five hours), so switching entries never waits for indexing.
- **现场模式** (room mode) is for a microphone in a reverberant room: windows that do not overlap confirm each other, so songs heard through a laptop speaker or a noisy room are still found.

### Two computers · Bluetooth

- The DJ's computer runs only the **发送端** (sender): it captures the Master, turns it into recognition features and streams them over Bluetooth Low Energy. No Set, index or video runs there.
- The projecting computer picks **蓝牙接收** as its input and chooses the current DJ among the connected ones, for handovers between DJs.
- A dropped link resumes by itself on both computers.

### Live desk

- A light preview of the projection; the whole show runs in one window, and nothing moves when following starts.
- Danmaku (scrolling or large in the middle) and Google Meet–style reactions (Noto's animated emoji; hold to send a stream, sweep to change the emoji).
- A sticker gallery of images, GIFs and words: drag one onto the preview to post it, then move, size, turn or take it down there; the projection follows.
- A dozen picture effects (glitch, RGB split, zoom blur, halftone, posterize, video wall, wave, scanlines, mosaic, black and white, lens…), each keyed on at its best strength and reordered by dragging. Effects touch only the video, never the words or stickers.

### Built for the show

- The computer and its screens stay awake during a show, and closing a window asks first.
- Decoder failures, a sound output that will not start, a lost projector screen or a lost file or input all recover without ending following.
- Video is decoded by the system hardware, the preview decodes nothing of its own and the picture redraws only when a frame is due, so the load stays low.

Every detail is in the [detailed guide](docs/guide.md).

## Build from source

Needs Rust (stable), CMake ≥ 3.22, Ninja and Qt 6.8 with Qt Shader Tools and Qt Image Formats.

```sh
cargo test -p kvj-recognize -p kvj-engine
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build
cmake --install build --prefix dist   # bundles Qt next to the app
```

On Windows run these from a Visual Studio developer prompt.

## License

KVJ is released under the [GNU GPL 3.0 or later](LICENSE); its live-following code is ported from [KDJ](https://github.com/kumoSleeping/KDJ). Release builds statically link the GPL-2.0-or-later
Rubber Band Library; its source and license are kept in
[`vendor/rubberband`](vendor/rubberband), and other notices are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
