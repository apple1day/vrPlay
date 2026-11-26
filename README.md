# VRPlay

iOS VR 视频播放器（类似 rPlayer 的核心能力）：360° / VR180 / 平面影院投影，左右(SBS) / 上下(TB) / 2D 立体格式，Cardboard 分屏 + 镜片畸变校正，陀螺仪头部追踪。

- 语言 / 框架：Swift 5.9、SwiftUI、Metal、AVFoundation、CoreMotion
- 最低系统：iOS 16.0（真机；模拟器没有陀螺仪）
- 播放内核：AVPlayer + `AVPlayerItemVideoOutput`（取 `CVPixelBuffer`，不使用 `AVPlayerLayer`）

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
- HDR 色调映射（目前请求 8 位输出）；8K 视频能否流畅取决于设备硬解能力

## 需要真机验证的地方

- **陀螺仪方向**：`HeadTracker` 里 CoreMotion → 渲染坐标系的转换是按公式推导的。抬头/低头/转头方向反了，改 `headRotation` 里 `right/up` 轴的符号即可。
- **畸变参数**：默认 k1=0.15、k2=0.05 是保守值，不同 Cardboard 盒子要在设置页微调。
- 自动识别对 2:1 的视频有歧义（360 单眼 / VR180 SBS），必要时手动切。
