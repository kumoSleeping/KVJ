# 测试

KVJ 的测试有三类。引擎和声学追踪的 Rust 测试用一条命令全部跑完；界面程序有两个无界面检查，要单独构建；还有几个读真实素材的工具，用来在自己的文件上量效果。

## Rust 测试

在仓库根目录运行：

```sh
cargo test --release
```

这会跑 `kvj-recognize` 和 `kvj-engine` 的全部测试，也会编译 `core/engine/examples` 里的工具，所以工具跟不上代码时这里就会报错。不加 `--release` 也能跑，声学追踪的测试会慢一些。测试只用程序里合成的声音和临时目录里的文件，不需要素材，也不碰用户的数据目录。

测试放在两个地方：

- `core/recognize/tests/live.rs`：声学追踪从头到尾的测试。用合成的音乐建索引，检查短窗口能找到正确的视频和位置，本地追踪在时钟速度不对时能找回真实速度，现场模式在混响里能跟上、对直连输入不改变结果。
- `core/engine/src` 各模块末尾的 `mod tests`：只测本模块，能用到模块内部的函数。

| 模块 | 测什么 |
|---|---|
| `runtime.rs` | 只追踪选中轨道上打开的条目；远跳要有后一次一致的听到才印证；跳转后保留时钟的速度；两处相似的位置留在前一处 |
| `audio_input.rs` | 声音输入的时间线：包时钟抖动、按渲染批次打的时间戳、漂移的时钟；输入中断；错误分类 |
| `decode.rs` | 解码和重采样：缓冲增长、错误输入、sinc 重采样的精度、取消 |
| `sound.rs` | 画面声音在跳转后从正确的那一帧读起 |
| `document.rs` | 媒体库合并、条目开关、轨道、存取不丢字段 |
| `index.rs` | 关掉或移动条目时索引保留；旧索引的清理 |
| `waveform.rs` | 时间线波形的列宽、颜色、静音、坏数据不压扁整条 |
| `rhythm/` | 速度分段：不同速度的歌分开、过渡不算一段、半速不算新段、取消 |
| `report/` | 错误报告去掉路径和账号、长度上限；版本号比较 |
| `update/` | 下载包的校验值、找本平台的安装包、更新失败后的回滚提示 |

`update/mod.rs` 里有一个只在 macOS 上手动跑的测试：它用 `hdiutil` 和 `codesign` 做一个磁盘映像再解包。

```sh
cargo test --release -p kvj-engine -- --ignored
```

## 界面程序的检查

配置时打开 `KVJ_BUILD_CHECKS` 会多构建两个命令行程序，不随应用发布：

```sh
cmake -S app -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DKVJ_BUILD_CHECKS=ON -DCMAKE_PREFIX_PATH=<Qt>/6.8.3/<platform>
cmake --build build --target kvj-player-check kvj-sound-check
```

- `kvj-player-check <视频> [起点秒数]...`：用系统解码器（macOS 的 AVFoundation，Windows 的 Media Foundation）以 60 Hz 跟一个移动的目标，包括向前向后跳，报告出第一帧的时间、每秒显示的帧数和晚了多少；再在暂停时跳转，检查显示的是目标那一帧。
- `kvj-sound-check <媒体> [起点秒数]`：以音量 0 播放画面的声音，速度按档位变化、微调、再回到 1，日志里每秒写出声音和画面差多少、有没有重新定位或断流。它用默认输出设备。

## 截图冒烟测试

设置 `KVJ_SNAPSHOT` 时，KVJ 启动后约 2.5 秒把窗口存成图片并退出。用 `KVJ_DATA_DIR` 指向一个空目录，媒体库和缓存就不会写进自己的数据：

```sh
QT_QPA_PLATFORM=offscreen KVJ_DATA_DIR=/tmp/kvj-data KVJ_SNAPSHOT=/tmp/kvj.png build/KVJ.app/Contents/MacOS/KVJ
```

界面上的偏好设置（声音开关、输出、淡入淡出等）不受 `KVJ_DATA_DIR` 影响，用的还是本机的设置，所以测试时不要去改它们。`offscreen` 用软件渲染，画不出效果。

## 用真实素材的工具

这些是 `kvj-engine` 的 example，用 `cargo run --release -p kvj-engine --example <名字> -- <参数>` 运行：

- `kvj-cli`：不开界面使用引擎。`devices` 列出声音输入，`prepare <文件夹>` 只建索引，`follow <文件夹> [--device ID] [--room]` 听输入并打印追踪结果，`alike` 列出媒体库里声音相同的条目，`update` 查最新发布的版本。媒体库和缓存放在 `KVJ_DATA_DIR`，没设就在临时目录。
- `kvj-follow-bench <kvj-sets.json> <缓存目录>`：把媒体库里的歌放进模拟的直连、笔记本外放和嘈杂房间，按引擎现场模式的节奏一轮轮查询，统计跟上、跟错和没跟上的比例，`--outside` 加入不在媒体库里的歌，`--diag` 看每种查询长度的检索名次和各道门槛。它是 `runtime.rs` 主循环的一份简化副本，主循环改了以后要对照着更新。
- `kvj-tempo <文件>...`：打印时间线上每个文件的速度分段。

## CI

`.github/workflows/build.yml` 只在手动触发或推送 `v*` 标签时运行。macOS 和 Windows 都会跑 Rust 测试、构建应用和两个检查、截一张冒烟截图；Windows 还用生成的 1080p 视频跑一遍 `kvj-player-check`。推送标签时再发布安装包。

## 没有自动测试的部分

- 界面（QML）和画面输出，只靠在应用里试和截图。
- `runtime.rs` 的追踪主循环本身：单元测试只覆盖其中的判断函数，整条循环要靠 `kvj-follow-bench` 和现场试用，开着「详细日志」看每一轮。
- 相似位置的扫描（`alike.rs`），以及相机、投屏、Windows 上的系统声音采集，都要在真机上试。
