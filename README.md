# VRPlay

iOS VR 视频播放器（类似 rPlayer 的核心能力）：360° / VR180 / 平面影院投影，左右(SBS) / 上下(TB) / 2D 立体格式，Cardboard 分屏 + 镜片畸变校正，陀螺仪头部追踪。

- 语言 / 框架：Swift 5.9、SwiftUI、Metal、AVFoundation、CoreMotion
- 最低系统：iOS 16.0（真机；模拟器没有陀螺仪）
- 播放内核：AVPlayer + `AVPlayerItemVideoOutput` 提供 VR 渲染帧。遇到播放错误时，可切换到 `AVPlayerLayer` 查看原始平面画面。

## 构建

```bash
brew install xcodegen
cd vrPlay
xcodegen generate
open VRPlay.xcodeproj
```

在 Xcode 里选择 Signing Team（改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`），连真机运行。

不想用 XcodeGen：新建一个 iOS App（SwiftUI，最低 iOS 16），把 `VRPlay/` 下所有 `.swift` 和 `.metal` 文件拖进去，
并在 Info.plist 中加入 `project.yml` 里 `info.properties` 的那些键（后台音频、文件共享、ATS 媒体例外、横竖屏）。

## 打开视频后没有画面

播放页会显示正在读取媒体、解码首帧或等待系统显示。VR 模式优先使用解码器提供的像素格式，可以直接渲染 8 位或 10 位双平面 YUV，以及 BGRA。取不到首帧或纹理转换失败时，播放器会尝试一次 8 位兼容输出。

若仍然失败，屏幕会标出出错环节。可以点“重试 VR”，也可以点“系统平面播放”查看原始视频。SBS 文件在系统平面模式中将显示原始并排的两幅画面。如果进度在走、画面仍看不见，也可以从播放设置中的“用系统播放器查看原始画面”进入平面模式。点“返回 VR”可重新进入沉浸播放。“复制错误”可保留错误文本，用于排查具体片源。

仓库的 `Tests/Fixtures/` 中有两段合成测试片。H.264 小片用于检查基本播放和左右眼分屏。另一段是 8192×2048、HEVC Main 10、12 秒的 360° SBS 片，左眼红绿交替，右眼始终为蓝色。该片每秒 1 帧，用于检查 8K 纹理和 10 位解码能否出画面。可在 Mac 上运行 `bash scripts/test-playback.sh` 检查模拟器中的实际画面。

## 代码结构

```
VRPlay/
├── App/        入口、AppDelegate、屏幕方向锁定
├── Model/      VRSettings（投影/布局/畸变参数 + 持久化）
│               FormatDetector（元数据 → 文件名 → 分辨率比例 三级自动识别）
│               LibraryStore（导入文件 / 相册 / 网络地址）
├── Player/     PlayerCore（AVPlayer 取帧）、HeadTracker（CoreMotion）、PlayerSession（视角/设置状态）
├── Render/     VRRenderer（Metal 管线）、Shaders.metal、Mesh（球面/平面网格）、MathUtils
└── UI/         LibraryView、PlayerView、SettingsSheet、VRMetalView（MTKView + 手势）
```

## 左右眼分屏的实现

视频每帧只解码一次，得到一张同时包含左右眼的纹理。渲染时：

1. 球面（360）/ 半球（VR180）/ 平面网格，相机位于球心，两只眼**朝向相同**（视差已经烘焙在视频里，不需要 IPD 偏移）。
2. 分屏模式在同一个 render pass 里 `setViewport` 两次（左半屏、右半屏），每次给着色器不同的 `uvScale / uvOffset`：
   - SBS：左眼 `(0.5,1)/(0,0)`，右眼 `(0.5,1)/(0.5,0)`
   - TB：左眼 `(1,0.5)/(0,0)`，右眼 `(1,0.5)/(0,0.5)`
3. 开启畸变时，场景先画到离屏纹理，再用全屏后处理 pass 做径向桶形预畸变 `r' = r(1 + k1·r² + k2·r⁴)`，输出到屏幕。
4. YUV→RGB 在片元着色器里完成，色彩矩阵（601/709/2020）和量化范围（video/full）按 `CVPixelBuffer` 的附件动态选择。

## 操作

| 场景 | 手势 |
|---|---|
| 单屏 | 单指拖动转视角；双指捏合缩放；单击显隐控制条；双击暂停/播放 |
| 分屏 | 单击暂停/播放；双击退出分屏并显示控制条；陀螺仪转视角 |

控制条按钮：回正视角、切换 VR 分屏、设置。设置页可手动改投影 / 立体格式 / 交换左右眼 / FOV / 畸变参数。
内容参数（投影、格式、交换眼）按视频记忆，观看参数（分屏、畸变、FOV 等）全局记忆；同时记忆播放进度。

## 当前能力与限制

支持：本地 mp4 / mov / m4v（H.264 / HEVC）、相册导入、Files 导入、iTunes 文件共享、http(s) 的 mp4 与 HLS(m3u8)。

不支持（需要后续迭代）：
- MKV / AVI / RMVB / TS、DTS / TrueHD 音轨、内嵌 ASS/PGS 字幕 —— 需接入 FFmpeg + VideoToolbox，`PlayerCore` 保持 `copyLatestFrame()` 接口即可替换
- SMB / WebDAV / FTP / 网盘
- 鱼眼、立方体贴图 / EAC 投影
- MV-HEVC（Apple 空间视频）
- 外挂字幕、画中画、AirPlay、锁屏控制
- HDR 色调映射。Metal 屏幕输出为 8 位 SDR。8K 播放取决于设备、编码规格和实际帧率。

## 需要真机验证的地方

- **陀螺仪方向**：`HeadTracker` 里 CoreMotion → 渲染坐标系的转换是按公式推导的。抬头/低头/转头方向反了，改 `headRotation` 里 `right/up` 轴的符号即可。
- **畸变参数**：默认 k1=0.15、k2=0.05 是保守值，不同 Cardboard 盒子要在设置页微调。
- 自动识别对 2:1 的视频有歧义（360 单眼 / VR180 SBS），必要时手动切。
