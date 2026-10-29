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

  <img src="docs/readme-assets/01-desk.webp" alt="KVJ 主界面" width="920">
</div>

---

**中文** · [English](README.en.md)

KVJ 是一款给 DJ 现场用的 VJ 软件。**声学追踪**可以认出 DJ 正在放的歌和放到的位置，让对应的视频同步播放；也可以手动操作两条轨道和相机画面（实验性），在画板上摆好观众看到的画面，再叠加弹幕、表情、贴图和效果。支持 macOS 和 Windows。

## 下载 & 安装

当前为预览版（非正式版本），可在 [Releases](https://github.com/kumoSleeping/KVJ/releases) 中查看全部版本。

<!-- release-package-size-badges:start -->
<p>
  <a href="https://github.com/kumoSleeping/KVJ/releases/latest/download/KVJ-macos-arm64.dmg"><img src="https://img.shields.io/badge/macOS-Apple_Silicon-black?style=for-the-badge&logo=apple&logoColor=white" alt="macOS Apple Silicon"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases/latest/download/KVJ-windows-x64.zip"><img src="https://img.shields.io/badge/Windows-x64-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows x64"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases"><img src="https://img.shields.io/badge/More-Releases-555555?style=for-the-badge&logo=github&logoColor=white" alt="More releases"></a>
</p>
<!-- release-package-size-badges:end -->

- **macOS**：打开 DMG，把 KVJ 拖进“应用程序”。安装包未经公证，首次打开若被拦截，请在“系统设置 → 隐私与安全性”中允许打开。捕获系统声音需要 macOS 14.2 或更高版本（12.3 起可用屏幕录制方式捕获），首次监听时请允许麦克风或系统录音权限。
- **Windows**：解压 ZIP，运行 `bin\KVJ.exe`。若提示缺少运行库，先运行同目录下的 `vc_redist.x64.exe`。

## 核心功能

### 声学追踪：音乐驱动的画面自动匹配

KVJ 会听 DJ 正在放的音乐，认出它对应媒体库里的哪段视频、放到了哪里，然后从那个位置、以同样的速度播放这段视频。DJ 调快调慢，画面的速度会跟着变；DJ 跳到歌的另一段或换了一首，画面也会跳过去，跳之前会再确认一次，避免误切。重复的副歌这类相似的段落也能分清。声学追踪只靠声音工作，不需要连接 DJ 软件、不用 MIDI，也不用提前在视频上打点，接 Master、系统声音或麦克风都可以；在嘈杂的房间里用麦克风时，可以打开现场模式。这样 VJ 就不用一直盯着 DJ 的操作手动对画面；对速和跳转也可以单独暂停，随时改回手动控制。

[声学追踪介绍 →](docs/acoustic-tracking.md)

### 播放器

- 左边是**媒体库**（加进来的文件夹，文件不复制）和**预备**（还没放进画面的来源和留着做贴图的图片）。视频拖到轨道左半边替换、右半边**追加到后面**。
- 底部有两条轨道**画面 1**、**画面 2**，布局和剪辑软件相似，显示缩略帧、与 KDJ 同款的整曲预览波形和 BPM 段；每条轨道有自己的时间、缩放和速度，可**同步播放**、**同步变速**、**缩放同步**，也可只显示一条（单轨）。
- 点轨道只放**光标**、不动画面；按「跳至」或回车才跳。每次跳转可设**跳转渐变**。
- 速度可在 −50 % 到 +50 % 间调节；← / → 像 pitch bend 一样临时**推拉**画面（按住时 0.7× / 1.5×），↑ / ↓ 每次调 1 %。
- 两条轨道的原声可各自开关和调音量（cue mix），Rubber Band 变速不变调；也可**只播放顶层声音**。
- 演出中电脑和屏幕保持唤醒，监听或投放时关闭窗口会再次确认；解码失败、声音输出无法启动、投影屏幕断开、单个文件丢失、声音输入中断都会自动恢复；视频由系统硬件解码，只在需要时解码和重绘，负载很低。

[设计原则 →](docs/principles.md)

[详细说明（英文） →](docs/guide.md)

### 画板和投放

- 窗口中间的**画板**显示观众看到的画面，画面也在这里调整。画面 1、画面 2 和相机都是**图层**，可以移动、缩放、置顶、铺满或完整显示，加圆角、圆形遮罩和羽化，用**分割线**遮住一侧。画面四周是**画外**，放在那里的东西观众看不到。
- 画板有**实时**和**投放**两种模式。实时模式下，每次改动观众立刻看到；投放模式下，观众一直看上一次投放的画面，改好后按「投放」（或空格）才换，可带渐变，⌘Z **撤回**到观众正在看的样子。右上角的**输出预览**始终显示观众正在看的画面。
- 轨道上的「投放画面 N」一键把那条轨道切到最上层；开着**跳转置顶**时，「跳至」会先把轨道切上去再播放。

[术语表 →](docs/glossary.md)

### 叠加和效果

- 弹幕（滚动、顶部、底部，像 B 站一样自动排轨道）、居中大字、Google Meet 风格的表情反应（Noto 动态表情，按住连发，Q–P 各发一个）。
- 贴图支持图片、GIF 和文字，可以在画板上移动、缩放、旋转和撤下，观众画面同步变化。
- 十余种画面效果（故障、RGB 分离、放射模糊、网点、色调分离、多画面、水波、扫描线、马赛克、黑白、鱼眼透镜等）组成**效果链**，从上往下依次叠加，每个作用在上面那些的结果上，拖动改顺序（下次打开还在），一键开到最佳强度，数字键 1–0 开关前十个。效果只作用于画面，不影响弹幕、表情和贴图。

### 相机（实验性）

- 「+ 相机」把摄像头画面作为图层加到画板上，和画面 1、画面 2 一样可以移动、缩放、遮罩、置顶，或放回预备。
- 相机暂时断开时图层会留在原处并说明原因，接回后自动恢复；系统不给相机时 KVJ 不会卡住。

## 从源码构建

需要 Rust（stable）、CMake ≥ 3.22、Ninja，以及带 Qt Shader Tools 和 Qt Image Formats 的 Qt 6.8。

```sh
cargo test -p kvj-recognize -p kvj-engine
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build
cmake --install build --prefix dist   # 把 Qt 一起打包到应用旁
```

Windows 上请在 Visual Studio 开发者命令提示符中运行以上命令。

## 许可证

KVJ 以 [GNU GPL 3.0 或更高版本](LICENSE)发布，其声学追踪代码移植自 [KDJ](https://github.com/kumoSleeping/KDJ)。发行包静态链接 GPL-2.0-or-later
的 Rubber Band Library；对应源码和许可文本保存在
[`vendor/rubberband`](vendor/rubberband)，其他说明见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
