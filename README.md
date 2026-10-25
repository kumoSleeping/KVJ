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

KVJ 是一款给 DJ 现场用的 VJ 软件。它首先是一个视频播放器：选一段素材，播放、暂停、跳到任意位置、手动调速度。其次是一个智能播放器：**音频对位**会监听 DJ 正在放的音乐，识别出它对应 Set 里的哪一段视频、播到了哪里，然后同步播放那段视频，随音乐跳转和变速。弹幕、表情和贴图可以叠加在画面上。支持 macOS 和 Windows。

## 下载 & 安装

当前为预览版（非正式版本），可在 [Releases](https://github.com/kumoSleeping/KVJ/releases) 中查看全部版本。

<!-- release-package-size-badges:start -->
<p>
  <a href="https://github.com/kumoSleeping/KVJ/releases/download/v0.1.0-rc1/KVJ-macos-arm64.dmg"><img src="https://img.shields.io/badge/macOS-Apple_Silicon-black?style=for-the-badge&logo=apple&logoColor=white" alt="macOS Apple Silicon"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases/download/v0.1.0-rc1/KVJ-windows-x64.zip"><img src="https://img.shields.io/badge/Windows-x64-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows x64"></a>
  <a href="https://github.com/kumoSleeping/KVJ/releases"><img src="https://img.shields.io/badge/More-Releases-555555?style=for-the-badge&logo=github&logoColor=white" alt="More releases"></a>
</p>
<!-- release-package-size-badges:end -->

- **macOS**：打开 DMG，把 KVJ 拖进“应用程序”。安装包未经公证，首次打开若被拦截，请在“系统设置 → 隐私与安全性”中允许打开。捕获系统声音需要 macOS 14.2 或更高版本（12.3 起可用屏幕录制方式捕获），首次监听时请允许麦克风或系统录音权限。
- **Windows**：解压 ZIP，运行其中的 `KVJ.exe`。

> [!NOTE]
> 视频由系统解码（macOS 为 VideoToolbox，Windows 为 Media Foundation），无需安装 FFmpeg。素材支持 mp4、m4v、mkv、mov 和 webm。

## 核心功能

### 播放器

- 左侧边栏是 Set 的树形列表：Set 下按来源文件夹分组列出素材，可直接把文件或文件夹拖进 Set。
- 每段素材都有开关，演出中也立即生效：关掉的素材离开时间线，也不再参与跟随，正在播的画面不受影响。
- 底部是视频剪辑软件风格的时间线：整个 Set 的缩略帧条与 KDJ 同款的整曲预览波形，支持触控板捏合缩放、双指滑动和“全览”。
- 点击时间线只移动光标，按“跳至光标处”或回车才真正跳转；每次跳转可设置 0.1–2 秒的渐变过渡。
- 速度可在 −50 % 到 +50 % 间调节；快捷键可像 pitch bend 一样临时推拉画面（按住时 0.7× / 1.5×），方向键每次调 1 %。
- “播放声音”可在单独的输出设备上播放素材原声，用 Rubber Band 变速不变调，调速和推拉都不会断音。
- 输出可选择屏幕、分辨率与帧率，“推荐”档会按屏幕和片源自动选择清晰度与帧率。

### 音频对位（智能跟随）

- 捕获 Master 输出、系统声音或麦克风，用声学指纹识别正在播放的是哪段素材、播到了哪里。
- **对速**让画面速度跟着音乐走，**跳转监测**在画面偏离超过阈值时自动跳到音乐所在的位置；两者可分别暂停，暂停的部分交还给手动控制。
- 整个 Set 预先建立索引（约 0.6 MiB / 分钟，最多约五小时），开关素材时无需等待重新索引。
- **现场模式**专为房间里的麦克风设计：在混响环境下，用多个互不重叠的识别窗口相互印证，也能找到经笔记本外放或嘈杂房间传来的歌曲。

### 双机 · 蓝牙

- DJ 的电脑只运行**发送端**：捕获 Master，提取识别特征，通过蓝牙低功耗传给投影电脑；不需要 Set、索引或视频，不打扰 DJ 软件。
- 投影电脑选择“蓝牙接收”作为输入，并可在多位已连接的 DJ 之间切换当前 DJ，方便多位 DJ 交接。
- 连接中断后两端会自动恢复。

### 直播台

- 投影画面的轻量预览，演出中所有操作都在一个窗口内完成，开始跟随时界面不会跳动。
- 弹幕（滚动或居中大字）、Google Meet 风格的表情反应（Noto 动态表情，按住连发，滑动切换表情）。
- 贴图库支持图片、GIF 和文字贴图：拖到预览上即发布，可在预览上移动、缩放、旋转和撤下，投影同步跟随。
- 十余种画面效果（故障、RGB 分离、放射模糊、网点、色调分离、多画面、水波、扫描线、马赛克、黑白、鱼眼透镜等），一键开到最佳强度，可拖动调整叠加顺序；效果只作用于视频，不影响弹幕和贴图。

### 演出稳定性

- 演出中电脑和屏幕保持唤醒，关闭窗口前会再次确认。
- 解码失败、声音输出无法启动、投影屏幕断开、单个文件或输入丢失时都会自动恢复，不会中断跟随。
- 视频由系统硬件解码，预览不额外解码，只有需要时才重绘，演出时负载很低。

完整的使用细节见[详细说明](docs/guide.md)（英文）。

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

KVJ 以 [GNU GPL 3.0 或更高版本](LICENSE)发布，其音频跟随代码移植自 [KDJ](https://github.com/kumoSleeping/KDJ)。发行包静态链接 GPL-2.0-or-later
的 Rubber Band Library；对应源码和许可文本保存在
[`vendor/rubberband`](vendor/rubberband)，其他说明见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
