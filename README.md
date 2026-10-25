# KVJ

Live VJ for DJs. KVJ is a video player first: pick an entry, play, pause, jump
anywhere and set the speed by hand. It is a smart player second: smart following
listens to what the DJ is playing, recognizes which video of the Set it belongs
to and where, and plays that video in sync, jumping and changing speed with the
music. Live words and emoji go over the picture. macOS and Windows.

- `core/recognize` — short-window acoustic landmark retrieval and verification.
- `core/engine` — Set document, indexing, native audio capture (Core Audio Tap,
  ScreenCaptureKit, WASAPI loopback), the following loop and a JSON C ABI
  (`core/engine/include/kvj.h`); `kvj-cli` drives it without a window.
- `app` — Qt 6 Quick shell: control window, projection window, system video
  decoding (VideoToolbox / Media Foundation) and the overlay.

## Two computers

The DJ's computer runs only the sender: **只发送** at the bottom right of the
window (or `KVJ --send`) puts the player away and opens a small window that
captures the Master, turns it into recognition features and streams them over
Bluetooth to the projecting computer; closing it brings the player back. Nothing
else runs there — no Set, index or video — so it stays light next to the DJ
software. The projecting
computer picks **蓝牙接收** as its input and chooses the current DJ among the
connected ones. Pair the two computers in the system's Bluetooth settings first.

## One window

Everything is in one window. The sidebar holds the Sets and the selected Set's
entries; each entry has a switch that decides whether it is followed, and it
works during the show too: at a handover between DJs the next DJ's entries are
turned on while the last ones stay on, and the last are turned off once the next
set is under way. Every entry is indexed either way, so switching never waits
for indexing; turning off the entry on the screen keeps the picture until
another entry is found. The middle is the live desk with the player; the right
side is smart following.

Under the preview are the output (screen, resolution, frame rate, full screen)
and **开始投放**. The **timeline** runs across the whole foot of the window and
is the player's transport, laid out like a video editor's timeline without
editing anything. Its top row has play and pause (Space; ← and → jump five
seconds), the speed (a bar from −50 % to +50 % and keys a percent at a time;
double-click the bar for 100 %) and **跳转渐变**: every jump, by hand or by
smart following, dissolves from the last picture over the chosen time
(0.1–2 s), or cuts when it is off. Under it, the seek bar of the entry on the
screen jumps the picture. Below that the Set's entries lie end to end as strips
of their frames, with a ruler in each entry's own time: pinch on the trackpad
(or ⌘/Ctrl + scroll) zooms about the pointer down to a few frames, a two-finger
swipe moves along, **全览** shows the whole Set again. Pressing or dragging on
the strip only sets a mark and leaves the picture alone; **跳到此处** (or a
double press) plays from the mark. While playing, the strip follows the
playhead unless it was touched in the last few seconds. Frames for the strip
are decoded small on one low-priority thread and kept up to 48 MB. At the end
of an entry the next one follows. Seeks aim ahead by what passes while the
decoder gets there, and a paused seek lands on the exact frame. Beside the
desk, the sticker gallery sits over the effects. **只发送** is at the top right.

**智能跟随音频跳转与调速** on the right takes the picture from the player while it
is on: the player's keys grey out and the timeline shows where following is.
**暂停** hands the picture back without stopping to listen; paused or stopped,
the player carries on from the same frame at the same speed. At its foot two
helpers show their work: **对速** keeps the speed with the music (its dot swings
at the followed speed), **跳转监测** watches how far the music is from the
picture against the jump threshold (2.5 s, or 2 s without a confirmation) and
ripples in amber once it is passed or the music goes quiet.

## Live desk

The live desk is a light preview of the
projection, danmaku (Enter sends; scrolling or large in the middle), Google
Meet–style reactions (Noto's animated emoji rising up the sides; hold to send a
stream), stickers and picture effects. Stickers are kept in a gallery of images (GIFs play), and words; one is posted
by dragging it onto the preview and letting go where it should be (double-click
posts it in the middle; images from the Finder dropped on the preview are added
and posted there). Posted stickers are changed on the preview and the
projection follows: press one to choose it and drag it around; the chosen one
has a point at each corner that sizes it, a point above that turns it (Shift:
steps of 15°, double-click: upright) and a key that takes it down (or Delete).
The size bar works on the chosen sticker, or else on the one posted last, and
sets the size of the next. Each effect (mosaic, RGB split, video wall, lens,
zoom blur, wave, glitch, scanlines, halftone, posterize, hue, black and white,
vignette) is off at 0 and comes in as its slider moves; effects touch only the
video, never the words or stickers. Danmaku from elsewhere can come in through
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
