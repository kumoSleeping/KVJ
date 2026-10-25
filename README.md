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

The DJ's computer runs only the sender: **发送** at the top left of the
window (or `KVJ --send`) puts the player away and opens a small window that
captures the Master, turns it into recognition features and streams them over
Bluetooth to the projecting computer; closing it brings the player back. Nothing
else runs there — no Set, index or video — so it stays light next to the DJ
software. The projecting
computer presses **蓝牙** beside it (or picks **蓝牙接收** as its input) and
chooses the current DJ among the connected ones. Pair the two computers in the system's Bluetooth settings first.

## One window

Everything is in one window, and nothing in it appears or moves when following
starts. The sidebar holds **发送** and **蓝牙** at the top, the Sets and the
selected Set's entries (videos only: mp4, m4v, mkv, mov, webm; a folder adds
the videos in it); each entry has a switch that takes effect at once, also
during the show: an entry that is off leaves the timeline and is not followed,
while the picture and its sound go on. At a handover between DJs the next DJ's
entries are turned on while the last ones stay on, and the last are turned off
once the next set is under way. Every entry is indexed either way, so switching
never waits for indexing: the index holds the whole Set, entries that are off
included (about 0.6 MiB a minute of sound, up to 192 MiB, some five hours; a
larger collection goes into several Sets). Turning off the entry on the screen asks again in red
under it; the second press goes on to the start of the next entry that is on,
with the jump's dissolve. The middle is the live desk with the player; the
right side is smart following (**音频对位**).

Under the preview are the output (screen, resolution, frame rate, full screen)
and **开始投放**. Resolution and frame rate start on **推荐**: as sharp as the
chosen screen shows and the video holds (480p, 720p, 1080p, or the source past
1600 rows), and every frame the video has up to 60; the other choices are as
before. The **timeline** runs across the whole foot of the window and is
the player's transport, laid out like a video editor's timeline without editing
anything. Its top row has the play key in the middle; to its left the Set, the
entry on the screen and where it is, the cursor with **跳至光标处**, **全览** and
**快捷键**; to its right the speed (a bar from −50 % to +50 % and keys a percent
at a time; **复原** or a double-click on the speed goes back to 100 %) and
**跳转渐变**: every jump, by hand
or by smart following, dissolves from the last picture over the chosen time
(0.1–2 s), or cuts when it is off. Under it, the whole Set's bar jumps the
picture (into whichever entry is there); zoomed in, a frame on it shows which
part of the Set the strip below shows, as in a video editor. Below that the Set's entries that are on lie end to
end as upright strips of the middle of their frames (enough to know the picture,
and many more of them) over their sound's waveform, with a ruler in each entry's own
time. The waveform is KDJ's whole-track preview (整曲预览): its height is the
energy, its colour how the lows (red), mids (green) and highs (blue) stand
against the rest of the file, and the part of the entry on the screen that has
played is dimmed. It is analysed once per file, 100 columns a second, on a
low-priority thread, and cached on disk, so it keeps its detail zoomed in. Pinch on the trackpad
(or ⌘/Ctrl + scroll) zooms about the pointer down to a few frames; a two-finger
swipe moves the strip with the fingers, along the axis it started on and on
through its momentum, and a mouse wheel (or a Windows touchpad) moves a tenth of
the view a notch, tilted or with Shift as well; scrolling over the bar above
does the same. **全览** shows the whole Set again. Pressing or dragging on the
strip only sets the cursor and leaves the picture alone; **跳至光标处** (or
Enter) plays from it. While playing, the strip follows the playhead unless
it was touched in the last few seconds. Frames for the strip are decoded small
on one low-priority thread and kept up to 48 MB. At the end of an entry the next
one that is on follows. Seeks aim ahead by what passes while the decoder gets
there, and a paused seek lands on the exact frame.

With **快捷键** on (it is by default), ← / →, A / D or 4 / 6 on the number pad
nudge the picture a second back or ahead without a jump, as a jog wheel does:
ahead at four times the speed for a third of a second, back at a tenth of the
speed for a little over a second (presses in a row add up); ↑ / ↓, W / S or
8 / 2 change the speed by 1 % and the speed bar follows; Enter plays from the
cursor.
Space does nothing: one touch of it during a show is too easy. No key acts while
words are being typed.

**播放声音** under the output plays the entry's own sound in step with the
picture (off by default, since the room hears the DJ) on an output of its own;
the output and the volume can be set before it is turned on. The engine decodes
it and Rubber Band (as in KDJ) stretches it to the picture's speed with its
pitch kept, so changing the speed or nudging never breaks the sound; it stays on
the picture by steering its speed a little, and seeks only on a jump. The
sticker gallery runs in a row under the reactions; the effects have the column
beside the desk.

**音频对位** on the right takes the picture from the player while it
is on: the player's keys grey out and the timeline shows where following is.
At its foot two helpers show their work: **对速** keeps the speed with the music
(its dot swings at the followed speed), **跳转监测** watches how far the music is
from the picture against the jump threshold (2.5 s, or 2 s without a
confirmation) and ripples in amber once it is passed or the music goes quiet.
Each pauses on its own and the player takes over what it did: with 跳转 paused
the player plays and seeks by hand while 对速 still sets its speed; with 对速
paused the speed is the player's and 跳转 still moves the picture to the music.
With both paused it only listens. Paused or stopped, the player carries on from
the same frame at the same speed.

## Room mode

**现场模式** is for listening through a microphone in the room. Reverberation
fills in where notes stop, so a short window seldom clears the acceptance gates
on its own. With it on, a window that misses them but has clear landmark and
onset evidence is taken once two others from the last 1.5 s agree on the same
recording and position. The usual gates are untouched, so direct capture
follows exactly as before. It starts on when a recording input is chosen and
off for captured or received audio.

## Live desk

The live desk is a light preview of the
projection, danmaku (Enter sends; scrolling or large in the middle), Google
Meet–style reactions (Noto's animated emoji rising from anywhere along the foot
of the screen; hold to send a stream, and sweep along the bar while holding to
change the emoji), stickers and picture effects. Stickers are kept in a gallery of images (GIFs play), and words; one is posted
by dragging it onto the preview and letting go where it should be (double-click
posts it in the middle; images from the Finder dropped on the preview are added
and posted there). Posted stickers are changed on the preview and the
projection follows: press one to choose it and drag it around; the chosen one
has a point at each corner that sizes it, a point above that turns it (Shift:
steps of 15°, double-click: upright) and a key that takes it down (or Delete).
The size bar works on the chosen sticker, or else on the one posted last, and
sets the size of the next. Each effect (mosaic, RGB split, video wall, lens,
zoom blur, wave, glitch, scanlines, halftone, posterize, hue, black and
white) has a key that turns it on at the strength it looks best at (or off;
dragged on over the other keys, it switches them the same way) and a bar that
fine-tunes it; they apply from the
top down, each to the picture the ones above made, and a grip at the left of
each drags it to another place in that order (kept between runs). Effects touch
only the video, never the words or stickers. Danmaku from elsewhere can come in through
`Live.say(text, from)` (`app/qml/Live.qml`).

## Load

Video is decoded and scaled by the system (VideoToolbox / Media Foundation with
D3D11), capped by the chosen resolution (default 720p) and frame rate (default
30). Three frames are held ahead and their buffers reused, the picture redraws
only when a new frame is due, and nothing is decoded while neither the output nor
the preview is up. The preview decodes nothing of its own: it takes a reduced
copy of the projected frame about 12 times a second, and its overlay moves on a
12 Hz clock. Each effect that is on is one pass; with every effect at 0 the
picture is drawn without any.

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
