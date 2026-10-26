# KVJ — detailed guide

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

The DJ's computer runs only the sender: **发送端** at the top right of the
window (or `KVJ --send`) puts the player away and opens a small window that
captures the Master, turns it into recognition features and streams them over
Bluetooth to the projecting computer; closing it brings the player back. Nothing
else runs there — no Set, index or video — so it stays light next to the DJ
software. The projecting
computer picks **蓝牙接收** as its input and
chooses the current DJ among the connected ones. Pair the two computers in the system's Bluetooth settings first.

## One window

Everything is in one window, and nothing in it appears or moves when following
starts. The top bar (the title bar itself on macOS) holds **发送端** and the
light / dark switch at the right. The Sets are in a drawer over the left side
of the canvas, put away at every start: the small key at the canvas's top
left (where the drawer's own head has it), or Ctrl+B (⌘B on macOS), brings it
out, and so do files dragged onto that key or to the canvas's left edge, to be
dropped on a Set. A press elsewhere on the canvas, the key in its head again or
Esc puts it away; choosing a Set leaves it out, and
so does a Set's menu or an add dialog in use. The drawer is one tree of the Sets: each Set
opens onto its entries (videos only: mp4, m4v, mkv, mov, webm; a folder adds
the videos in it and its subfolders), grouped by the folders they came from;
the chosen Set is the one played and followed, and files dropped on a Set go
into it. Each entry has a switch that takes effect at once, also
during the show: an entry that is off leaves the timeline and is not followed,
while the picture and its sound go on. At a handover between DJs the next DJ's
entries are turned on while the last ones stay on, and the last are turned off
once the next set is under way. Every entry is indexed either way, so switching
never waits for indexing: the index holds the whole Set, entries that are off
included (about 0.6 MiB a minute of sound, up to 192 MiB, some five hours; a
larger collection goes into several Sets). Turning off the entry on the screen asks again in red
under it; the second press goes on to the start of the next entry that is on,
with the jump's dissolve. While it asks the drawer is not put away: a press
outside it, Esc or its key answers no first. The canvas, across the whole
width, is the live desk with the player, then smart following
(**音频对位**) and the effects at the right.

Every entry is on one of four **tracks**: the main track, where entries go
unless told otherwise and which the player and the timeline play, and three aux
tracks (画面 2, 3 and 4) for pictures shown beside it. Following listens for one
track only, the main one unless another is chosen: entries on the others are
never matched, however alike their sound, though they stay in the index, so
moving an entry to another track (while not following, like other changes to a
Set) never waits for indexing. Following can start once the followed track has
an entry with sound that is on.

Under the preview are the output (screen, resolution, frame rate, full screen)
and **开始投放**. Resolution and frame rate start on **推荐**: as sharp as the
chosen screen shows and the video holds (480p, 720p, 1080p, or the source past
1600 rows), and every frame the video has up to 60; the other choices are as
before. The **timeline** runs across the whole foot of the window, laid out
like a video editor's track area without editing anything: a row a source under one
ruler. A slim bar on top holds what belongs to no one track: the Set and the
entry the main track shows, where it is (and what is left of it), the cursor
with **跳至光标处**, the zoom keys (− **全览** +), **快捷键** and **跳转渐变**:
every jump, by hand or by smart following, dissolves from the last picture over
the chosen time (0.1–2 s), or cuts when it is off. Under it the whole
timeline's bar: zoomed in, a frame on it shows which part the rows show, and
drags along or, by its ends, wider or narrower; a press well away from it only
sets the cursor. Then the ruler, in each entry's own time along the longest row
(plain seconds while every row is empty).

The rows come next, two in view; a third and more are reached by scrolling, as
an editor's tracks are (a scroll bar shows once there are more than fit). The
main track (画面 1) is always the first row, also while it is empty; each aux
track (画面 2, 3, 4) that has entries or was added with **+ 轨道** (at the top
left of the rows) has its own, and so does each camera taken in (**+ 轨道**
lists the cameras only while its menu is open). A row's header holds the
source's own small live picture (a press puts it in the preview's chosen slot,
PVW; on the air it has an ink edge and PGM, in the preview a faint one and PVW),
its name, an ear on the track following listens to, and ⋯ (an aux track's
**跟随主轨速度**, and **移除轨道** for an empty aux track or a camera). Across the
rest of the row runs its own play bar over its lane, so every track is
operated on its own: play and pause, where it is in its entry, a seek track
over the whole row (a press or drag moves that track's picture there; on the
main track a jump into another entry starts it playing, and while the timeline
is parked it brings the picture over to this Set), the speed with − / + a
percent at a time, a small bar and **复原** (or a double-click on the speed),
who sets the speed (手动, 智能跟随, 跟主轨速度 …), and **循环** or **播完即停**
after the row's last entry (kept per track). An aux track plays on its own
clock beside the main one; **跟随主轨速度** plays it at its own speed times the
main track's, so it keeps pace when the main track's tempo changes. A
track's keys rest while smart following leads its player.

The lane shows the track's entries that are on end to end as upright strips of
the middle of their frames (enough to know the picture, and many more of them)
over their sound's waveform, under their tempo, a block a section with its
BPM. The waveform is KDJ's whole-track preview (整曲预览): its height is the
energy, its colour how the lows (red), mids (green) and highs (blue) stand
against the rest of the file, and the part of the entry on the screen that has
played is dimmed. It is analysed once per file, 100 columns a second, on a
low-priority thread, and cached on disk, so it keeps its detail zoomed in. An
empty track says **把素材拖到这里**: entries dragged from the drawer, or files
from the desktop, dropped anywhere on a track's row go on that track (the row
lights up while they hover); a camera's lane just says it is live. All rows
share one view. Pinch on the trackpad (or ⌘/Ctrl/Alt + scroll) zooms about the
pointer down to a few frames; a sideways two-finger swipe moves the lanes with
the fingers, along the axis it started on and on through its momentum, and an
upright one scrolls the rows once there are more than fit (else it moves the
lanes too); a mouse wheel moves a tenth of the view a notch, tilted or with
Shift, and upright scrolls the rows once there are more than fit; over the
headers it always scrolls the rows. **全览** shows everything again. Pressing or
dragging on the main track's lane or on the ruler only sets the cursor and
leaves the picture alone; **跳至光标处** (or Enter) plays from it. A press or
drag on an aux track's lane moves that track's picture there at once, playing
or paused as it was. While playing, the lanes follow the main playhead unless
they were touched in the last few seconds. Frames for the lanes are decoded
small on one low-priority thread and kept up to 48 MB. At the end of an entry
the next one that is on follows. Seeks aim ahead by what passes while the
decoder gets there, and a paused seek lands on the exact frame. Aux tracks are
never followed unless chosen for it (below), and never identified otherwise.

At the right end of the rows sits **音频对位** pressed into a strip as tall as
one row, beside the first: what following does (未监听, 监听中 or 跟随中, and
the title), the input's level, the ear (开始监听 / 停止监听), **跟随** (开始跟随; 暂停 while it
leads), the crosshair (跳至此处), the input, which track is followed, and the
two helpers as small keys, **对速** with its swinging dot and **跳转** with its
ring and a line to the jump threshold; a press pauses or resumes one, and the
pointer over one tells how it is doing. ⋯ opens the rest: the channels,
现场模式, 画面偏移, both helpers in full with the threshold, the Bluetooth DJs
and the last error (a dot on ⋯ says a DJ asks to pair). Following works on one
track at a time, the main one by default; only tracks with an entry that has
sound are offered (a camera, a stream or a track of silent entries is not),
and the choice is fixed while listening. While following runs, its small
picture stands at the strip's left, in the panel's tone until it has found the
music; stopped, it is gone and the rows take the room.

With **快捷键** on (it is by default), ← / → or A / D
nudge the picture back or ahead without a jump, as a pitch bend does: while
held, the picture plays at 0.7 or 1.5 of its speed, and let go it is back at
its speed (paused, a press steps a second); ↑ / ↓ or W / S change the speed by 1 % and the speed bar follows; Enter plays from the
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

**音频对位** takes the picture from the player while it
is on: the player's keys grey out and the timeline shows where following is.
Its two helpers show their work: **对速** keeps the speed with the music
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
onset evidence is taken once two others from the last 3 s agree on the same
recording and position, each heard at least 0.5 s before the next: windows
125 ms apart share most of their audio, so only ones that do not overlap count
as separate evidence. While searching, such a window's position is also checked
again where the music should be by now, against neighbours 0.4–3.2 s away, so
one lucky retrieval is enough to find a song that retrieval seldom ranks first.
The usual gates are untouched, so direct capture follows exactly as before. It
starts on when a recording input is chosen and off for captured or received
audio. `kvj-follow-bench` (an engine example) measures it on a Set's own songs
through a simulated laptop speaker and a noisy room, and on songs outside it.

## Live desk

The live desk is a light preview of the
projection, danmaku (Enter sends; scrolling, held at the top or the foot as on
Bilibili, or large in the middle; small, medium or large), Google
Meet–style reactions (Noto's animated emoji rising from anywhere along the foot
of the screen; hold to send a stream, and sweep along the bar while holding to
change the emoji), stickers and picture effects. Stickers are kept in a gallery of images (GIFs play), and words; one is posted
by dragging it onto the preview and letting go where it should be (double-click
posts it in the middle; images from the Finder dropped on the preview are added
and posted there). Posted stickers are changed on the preview and the
projection follows: press one to choose it and drag it around; the chosen one
has a point at each corner that sizes it, a point above that turns it (Shift:
steps of 15°, double-click: upright); Delete takes it down. **编辑** (next to the
size bar) puts the stickers in edit mode: every posted one shows a × on its top
right corner that takes it down, and every one in the gallery a × that takes it
out of the gallery; **完成** or Esc ends it. The preview has the projection's
shape (its window's, or the screen it fills) and sits on a stage that reaches
half the picture again on every side, as far as the desk has room: a sticker
let go or dragged there stays offstage (faint on the preview, unseen by the
audience) until it is dragged into the picture.
The size bar works on the chosen sticker, or else on the one posted last, and
sets the size of the next. Each effect (mosaic, RGB split, video wall, lens,
zoom blur, wave, glitch, scanlines, halftone, posterize, hue, black and
white) has a key that turns it on at the strength it looks best at (or off;
dragged on over the other keys, it switches them the same way) and a bar that
fine-tunes it; they apply from the
top down, each to the picture the ones above made, and a grip at the left of
each drags it to another place in that order (kept between runs) while the
effects panel's **编辑** is on. The number
keys 1–9 and 0 (on the number pad too) switch the first ten effects in the list,
whose rows show their key; the effects are the column at the window's right edge; , and . make the last effect switched (or tuned)
5 % weaker or stronger. An effect tuned that way and then switched off keeps that
strength as its own (a dot on its key); 重置 gives every effect back the strength
it came with. The effects panel's own 快捷键 turns these keys off. Effects touch
only the video, never the words or stickers. Danmaku keeps out of each other's way
as on Bilibili: every scrolling line crosses in the same seven seconds (a long
one moves faster) on the topmost lane of the upper three quarters where the line
before it has come fully in and will be gone before this one catches it; top and
bottom lines hold, centred, for four and a half seconds on the first free lane
down from the top or up from the foot. Lanes, sizes and timing are decided once
in `Live`, so the preview and the projection show the same. Danmaku from
elsewhere can come in through `Live.say(text, from, { mode, size })`
(`app/qml/Live.qml`; mode `scroll`, `top` or `bottom`, size a share of the
screen's height).

## Compositing

The canvas is laid out as a vision mixer, left to right: the program (what is
on the air, on the stage where stickers are placed), with the output in one row
under it (the picture's sound in a popover at its end) and the sticker gallery
under that, always out, the words and reactions folded under its **弹幕 · 表情**
key (they are used less); then the preview (PVW) with its slot settings and the
layout keys; then the effects. At the foot, the track area (see the timeline):
each row's header shows that source's live picture, and pressing it puts the
source in the preview's chosen slot; a header on the air has an ink edge and a
PGM tag, one in the preview a faint edge and a PVW tag. Cameras are rows too
(+ 轨道 → 相机; the list of cameras is read only then). A source is decoded
(or a camera opened) only while it is on the air or the operator's window
shows it, and at most six videos decode at once: past that a jump cuts
instead of dissolving.

The projection shows a composition of picture sources (the four tracks,
`track:0`–`track:3`, and cameras, `camera:<id>`) in a layout of slots, mixed the
way a vision mixer does it. **PGM** (program) is what the audience sees; **PVW**
(preview) is what the operator puts together next, on its own monitor, without
touching the air. Until anything is changed both are one slot with the main
track in full, so the projection looks exactly as it did without a mixer.

A layout's slots each hold a source, a place and size in shares of the
projected picture (a slot may reach past its edges), an order (z), a fit —
**铺满** fills the slot and crops the picture's longer way, **完整** shows all of
it with bands — and a mask. Masks are a rectangle, a rounded rectangle (radius),
the ellipse that fits the slot, or a closed curve through points that are
dragged on the monitor (a smooth Catmull-Rom curve through all of them;
double-click on the slot adds a point on the nearest stretch, Alt-click or
Delete takes the chosen one away, three always stay). Every mask has a feather
that softens its edge inwards. Radius and feather are shares of the slot's
shorter side, so the small monitors and the projection cut the same shape.

On the PVW monitor a slot is chosen by pressing it, moved by dragging it and
sized by its corners; edges snap to the picture's edges and middle, the arrow
keys nudge the chosen slot (Shift: more). Under the monitor are its slots (+
adds one, the bin removes the chosen one) and the chosen slot's source, fit,
mask, radius, feather and place in per cent. The layout keys start a preview
from a preset with the sources taken in their order: 单画面, 画中画 (its inset in
whichever corner of the key is pressed), 左右, 上下, 2×2 and 1 大 + 2 小.

**应用** puts the preview on the air: a cut, or with **渐变** on a dissolve of
0.3–2 s. During a dissolve both layouts are drawn live, the one before on black
fading out over the new one, by time alone, so the projection and the PGM
monitor end it at the same moment. **还原** gives the preview back what is on
the air. Both layouts and the dissolve length are kept between runs.

The composition takes the place the picture had: the effects apply to all of
it, and the stickers and overlay go over it. Each window wraps every source into
one texture however many slots, monitors or dissolve layers show it. Without
GPU shaders (the software renderer) slots are drawn without their masks.

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
