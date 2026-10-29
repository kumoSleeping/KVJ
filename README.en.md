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

KVJ is live VJ software for DJs. It is a video player first: two tracks, each played, paused, jumped anywhere and set to a speed by hand, laid out on a board as the picture the audience sees. It is a smart player second: **声学追踪** (acoustic tracking) listens to what the DJ is playing, recognizes which video of the library it is, where and how fast, and plays that video in sync, jumping and changing speed with the music. Danmaku, reactions and stickers go over the picture. macOS and Windows.

## Download & install

This is a preview (pre-release) build; every version is listed under [Releases](https://github.com/kumoSleeping/KVJ/releases).

<!-- release-package-size-badges:start -->
<p>
  <a href="https://github.com/kumoSleeping/KVJ/releases/latest/download/KVJ-macos-arm64.dmg"><img src="https://img.shields.io/badge/macOS-Apple_Silicon-black?style=for-the-badge&logo=apple&logoColor=white" alt="macOS Apple Silicon"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases/latest/download/KVJ-windows-x64.zip"><img src="https://img.shields.io/badge/Windows-x64-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows x64"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases"><img src="https://img.shields.io/badge/More-Releases-555555?style=for-the-badge&logo=github&logoColor=white" alt="More releases"></a>
</p>
<!-- release-package-size-badges:end -->

- **macOS**: open the DMG and drag KVJ into Applications. The app is not notarized; if macOS blocks the first launch, allow it under System Settings → Privacy & Security. Capturing system sound needs macOS 14.2 or later (screen-recording capture from 12.3); allow the microphone or system audio recording when KVJ first listens.
- **Windows**: unzip and run `bin\KVJ.exe`. If Windows reports a missing runtime, run `vc_redist.x64.exe` from the same folder first.

> [!NOTE]
> Video is decoded by the system (VideoToolbox on macOS, Media Foundation on Windows), so no FFmpeg is needed. Entries can be mp4, m4v, mkv, mov and webm.

## Features

### Player

- At the left are the **library** (folders added, files never copied) and **预备** (ready: sources not on the picture yet, and pictures kept for stickers). A video dropped on a track's left half replaces what is there, on its right half it goes after it.
- Two tracks at the foot, **画面 1** and **画面 2**, as in a video editor: frame strips, KDJ's whole-track preview waveform and BPM sections, each with its own time, zoom and speed; they can **play in sync**, **change speed together** and **zoom together**, or one alone is shown (single track).
- Pressing a track only places its **cursor** and never moves the picture; **跳至** (jump) or Enter plays from it. Every jump can dissolve.
- Speed goes from −50 % to +50 %; ← / → **nudge** the picture like a pitch bend (0.7× / 1.5× while held), ↑ / ↓ change it by 1 %.
- Each track's own sound can be on with its own volume (a cue mix), stretched by Rubber Band with its pitch kept; or only the topmost track's is heard.

### Board and 投放

- The **board** in the middle is the audience's picture, seen and made in one place: 画面 1, 画面 2 and cameras are **layers** that are moved, sized, raised, filled or fitted, rounded, masked to a circle, feathered and cut by **split lines**. Around the picture is the **offstage** area, which the audience does not see.
- The board has two modes: in **实时** (live) every change is on the air at once; in **投放** (staged) the audience keeps the picture last put out until **投放** (or Space) puts the new one out, with a dissolve if wanted, and ⌘Z **undoes** the board back to what is on the air. **输出预览** at the top right always shows what the audience sees.
- A track's **投放画面 N** cuts that track to the top in one press; with **跳转置顶** on, a jump first puts its track on top and then plays.

### 声学追踪 (acoustic tracking)

- Captures the Master, the system's sound or a microphone, and recognizes which entry is playing, where and how fast — among the entries of the **followed track** only (画面 1 by default).
- Finding: every 125 ms it takes the last 0.55 s of sound, pairs the **peaks** of its spectrum into **landmarks** and lets them vote in an **index** of the library to **search** out positions and speeds (0.80–1.25×, keylock on or off). It then **verifies** them frame by frame on how each band rises and falls, and takes a position as an **observation** only if it beats every other position clearly (the **margin**, not only the likeness), so a repeated chorus does not lock wrong.
- Following: the picture follows not any one recognition but a **follow clock** fitted to the last 3 s of observations. **对速** (speed follow) keeps the picture's speed with the clock; once the picture is past the 2.5 s **jump threshold**, or on another entry, **跳转** (jump) moves it to where the music is — only once a second hearing half a second later agrees (**jump confirmation**), so the picture never cuts away and back. Each pauses on its own and hands its part back to the player; **listening** alone judges without moving the picture.
- Once locked it **tracks** near the expected position only, fast and steady; when that fails it searches the whole library again.
- The whole library is indexed ahead (about 0.6 MiB a minute, some five hours), entries off the tracks included, so placing one never waits.
- **现场模式** (room mode) is for a microphone in a reverberant room: windows that do not overlap **corroborate** each other, so songs heard through a laptop speaker or a noisy room are still found.

### Overlay and effects

- Danmaku (scrolling, top or bottom, laned as on Bilibili), large words in the middle, and Google Meet–style reactions (Noto's animated emoji; hold to send a stream, Q–P send one each).
- Stickers of images, GIFs and words, moved, sized, turned and taken down on the board; the audience's picture follows.
- A dozen picture effects (glitch, RGB split, zoom blur, halftone, posterize, video wall, wave, scanlines, mosaic, black and white, lens…) form an **effect chain**: they apply from the top down, each to the picture the ones above made, are reordered by dragging (kept between runs), keyed on at their best strength, and the number keys 1–0 switch the first ten. Effects touch only the picture, never the danmaku, reactions or stickers.

### Two computers · Bluetooth (experimental)

- An idea, partly built: hearing and showing on two computers. The DJ's computer runs only the **发送端** (sender), which turns the Master into recognition features and sends them over Bluetooth Low Energy — not the sound itself, and with no library, index or video there; the projecting computer picks **蓝牙接收** as its input. It is not planned to grow further.

### Built for the show

- The computer and its screens stay awake during a show, and closing the window while listening or projecting asks first.
- Decoder failures, a sound output that will not start, a lost projector screen, a lost camera or file and a broken sound input all recover without ending tracking.
- Video is decoded by the system hardware, a source only while it is needed, and the picture redraws only when a frame is due, so the load stays low.

## Documents

- [Glossary](docs/glossary.md) (Chinese): KVJ's terms, and how acoustic tracking works.
- [Design principles](docs/principles.md) (Chinese): the choices that run through the whole app.
- [Detailed guide](docs/guide.md): every detail of using it.

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

KVJ is released under the [GNU GPL 3.0 or later](LICENSE); its acoustic tracking code is ported from [KDJ](https://github.com/kumoSleeping/KDJ). Release builds statically link the GPL-2.0-or-later
Rubber Band Library; its source and license are kept in
[`vendor/rubberband`](vendor/rubberband), and other notices are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
