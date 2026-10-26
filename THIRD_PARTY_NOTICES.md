# Third-party notices

KVJ is licensed under GPL-3.0-or-later (see `LICENSE`). Its live-following code is
ported from KDJ (https://github.com/kumoSleeping/KDJ, GPL-3.0-or-later), commit
00f377a, the last commit before KDJ removed Live VJ. The bug-report scrubbing, the
report collector (`workers/bug-collector`) and the release comparison follow KDJ's
current ones.

| Component | Use | License |
|---|---|---|
| Qt 6 (Qt Base, Qt Declarative, Qt Svg, Qt Image Formats, Qt Multimedia) | application shell, dynamically linked | LGPL-3.0 |
| Qt Shader Tools | compiles the effect shader (build time only) | GPL-3.0 |
| cpal 0.18.1 (`vendor/cpal-0.18.1`, patched as described in `KDJ-PATCH.md`) | audio capture | Apache-2.0 |
| symphonia | audio decoding for indexing and the picture's sound | MPL-2.0 |
| Rubber Band Library 4.0.0 (`vendor/rubberband`, unmodified; Copyright 2007-2024 Particular Programs Ltd) | the picture's sound stretched to the picture's speed, pitch kept; built from its single-file unit, statically linked | GPL-2.0-or-later |
| rustfft | spectra | MIT OR Apache-2.0 |
| objc2 family, windows-sys / windows | system bindings | MIT OR Apache-2.0 / MIT OR Apache-2.0 |
| serde, serde_json, anyhow, tracing | runtime | MIT OR Apache-2.0 |
| ureq, native-tls, regex, semver | bug reports (sent only when confirmed) and the update check, over the system's TLS | MIT OR Apache-2.0 |
| Corrosion | links the Rust engine into the CMake build (build time only) | MIT |
| Lucide icons (`app/qml/icons`, redrawn paths) | interface icons | ISC |
| Noto Animated Emoji by Google (`app/qml/emoji`, scaled to 192 px) | reactions | CC BY 4.0 |

Video is decoded by the operating system (AVFoundation/VideoToolbox on macOS,
Media Foundation on Windows); no decoder is bundled.
