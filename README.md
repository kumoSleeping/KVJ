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

KVJ 是一款给 DJ 现场用的 VJ 软件。它首先是一个视频播放器：两条轨道，各自播放、暂停、跳到任意位置、手动调速度，在画板上摆成观众看到的画面。其次是一个智能播放器：**声学追踪**会听 DJ 正在放的音乐，识别出它是媒体库里哪一段视频、播到了哪里、多快，然后同步播放那段视频，随音乐跳转和变速。弹幕、表情和贴图可以叠加在画面上。支持 macOS 和 Windows。

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

> [!NOTE]
> 视频由系统解码（macOS 为 VideoToolbox，Windows 为 Media Foundation），无需安装 FFmpeg。素材支持 mp4、m4v、mkv、mov 和 webm。

## 核心功能

### 播放器

- 左边是**媒体库**（加进来的文件夹，文件不复制）和**预备**（还没放进画面的来源和留着做贴图的图片）。视频拖到轨道左半边替换、右半边**追加到后面**。
- 底部两条轨道**画面 1**、**画面 2**，像剪辑软件一样：缩略帧条、与 KDJ 同款的整曲预览波形和 BPM 段，各有自己的时间、缩放和速度；可**同步播放**、**同步变速**、**缩放同步**，也可只显示一条（单轨）。
- 点轨道只放**光标**、不动画面；按「跳至」或回车才跳。每次跳转可设**跳转渐变**。
- 速度可在 −50 % 到 +50 % 间调节；← / → 像 pitch bend 一样临时**推拉**画面（按住时 0.7× / 1.5×），↑ / ↓ 每次调 1 %。
- 两条轨道的原声可各自开关和调音量（cue mix），Rubber Band 变速不变调；也可**只播放顶层声音**。

### 画板和投放

- 窗口中间的**画板**就是观众看到的画面，在这里看、也在这里改：画面 1、画面 2 和相机都是**图层**，可以移动、缩放、置顶、铺满或完整显示，加圆角、圆形遮罩和羽化，用**分割线**遮住一侧。画面四周是**画外**，放在那里的东西观众看不到。
- 画板有两种模式：**实时**下每一下改动观众立刻看到；**投放**下观众一直看上一次投放的画面，改好后按「投放」（或空格）才换，可带渐变，⌘Z **撤回**到观众正在看的样子。右上角的**输出预览**始终显示观众正在看的画面。
- 轨道上的「投放画面 N」一键把那条轨道切到最上层；开着**跳转置顶**时，「跳至」会先把轨道切上去再播放。

### 声学追踪

- 捕获 Master 输出、系统声音或麦克风，识别出正在播放的是哪段素材、播到了哪里、多快。只听**追踪的轨道**（默认画面 1）上的素材。
- 怎么找：每 125 毫秒取最近 0.55 秒的声音，把频谱上的**尖峰**两两连成**地标**，在媒体库的**索引**里投票**检索**出候选位置和速度（0.80–1.25×，DJ 开不开 keylock 都能找到）；再逐帧比对各频带的起落来**校验**，只有比所有别的位置都明显更像（看**领先**，不只看像不像），才接受为一次**观测**，所以重复的副歌不会锁错。
- 怎么跟：画面不跟某一次识别，而跟由最近 3 秒观测拟合出的**播放时钟**。**对速**让画面速度跟着时钟走；偏离超过 2.5 秒的**跳转阈值**或换了素材时，**跳转**把画面移到音乐所在的位置，而且要隔半秒再听到一次才跳（**远跳印证**），不会切走又切回。两者可分别暂停，暂停的部分交还给手动控制；只**监听**时只判断、不动画面。
- 锁定后只在预计位置附近**跟踪**，又快又稳；跟不上时再检索整个媒体库。
- 整个媒体库预先建立索引（约 0.6 MiB / 分钟，最多约五小时），没放上轨道的素材也在内，放上轨道时无需等待。
- **现场模式**专为房间里的麦克风设计：在混响环境下，用多个互不重叠的识别窗口相互**印证**，也能找到经笔记本外放或嘈杂房间传来的歌曲。

### 叠加和效果

- 弹幕（滚动、顶部、底部，像 B 站一样自动排轨道）、居中大字、Google Meet 风格的表情反应（Noto 动态表情，按住连发，Q–P 各发一个）。
- 贴图：图片、GIF 和文字，在画板上移动、缩放、旋转和撤下，观众画面跟随。
- 十余种画面效果（故障、RGB 分离、放射模糊、网点、色调分离、多画面、水波、扫描线、马赛克、黑白、鱼眼透镜等）组成**效果链**：从上往下依次叠加，每个作用在上面那些的结果上，拖动改顺序（下次打开还在），一键开到最佳强度，数字键 1–0 开关前十个。效果只作用于画面，不影响弹幕、表情和贴图。

### 双机 · 蓝牙（实验性）

- 一个设想，已部分实现：把“听”和“放”拆到两台电脑。DJ 的电脑只运行**发送端**，把 Master 变成识别特征经蓝牙低功耗发给投影电脑，不传声音本身，也不需要媒体库、索引或视频；投影电脑选择“蓝牙接收”作为输入。目前不计划继续扩展。

### 演出稳定性

- 演出中电脑和屏幕保持唤醒，监听或投放时关闭窗口会再次确认。
- 解码失败、声音输出无法启动、投影屏幕断开、相机或单个文件丢失、声音输入中断时都会自动恢复，不会中断追踪。
- 视频由系统硬件解码，来源只在需要时才解码，画面只在有新帧时重绘，演出时负载很低。

## 文档

- [术语表](docs/glossary.md)：KVJ 的用词，以及声学追踪是怎么实现的。
- [设计原则](docs/principles.md)：贯穿整个软件的取舍。
- [详细说明](docs/guide.md)（英文）：完整的使用细节。

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
