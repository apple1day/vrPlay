import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var session: PlayerSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("投影", selection: $session.settings.projection) {
                        ForEach(Projection.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("立体格式", selection: $session.settings.layout) {
                        ForEach(StereoLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("交换左右眼", isOn: $session.settings.swapEyes)
                    if session.settings.projection == .flat {
                        sliderRow("屏幕大小", value: $session.settings.flatScale, range: 0.4...2.0, format: "%.2f×")
                    }
                    Button("自动识别格式") { session.autoDetect() }
                } header: {
                    Text("视频格式")
                } footer: {
                    Text(session.detectionNote.isEmpty
                         ? "自动识别可能不准（例如 2:1 的视频既可能是 360 单眼，也可能是 VR180 左右格式），请按实际情况手动调整。"
                         : session.detectionNote)
                }

                Section("观看方式") {
                    Picker("显示", selection: $session.settings.displayMode) {
                        ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("陀螺仪追踪", isOn: $session.settings.gyroEnabled)
                    sliderRow("视场角 FOV", value: $session.settings.fov, range: 50...120, format: "%.0f°")
                    Button("视角回正") { session.recenter() }
                }

                Section {
                    Toggle("镜片畸变校正", isOn: $session.settings.distortionEnabled)
                    sliderRow("畸变 k1", value: $session.settings.k1, range: 0...0.6, format: "%.2f")
                    sliderRow("畸变 k2", value: $session.settings.k2, range: 0...0.4, format: "%.2f")
                    sliderRow("镜片中心偏移", value: $session.settings.lensOffset, range: -0.3...0.3, format: "%.2f")
                    sliderRow("画面缩放", value: $session.settings.zoom, range: 0.7...1.5, format: "%.2f×")
                    Button("恢复默认", role: .destructive) {
                        let d = VRSettings()
                        session.settings.k1 = d.k1
                        session.settings.k2 = d.k2
                        session.settings.lensOffset = d.lensOffset
                        session.settings.zoom = d.zoom
                        session.settings.distortionEnabled = d.distortionEnabled
                    }
                } header: {
                    Text("Cardboard 镜片（仅分屏模式生效）")
                } footer: {
                    Text("画面边缘出现彩边或拉伸时，先调 k1，再微调 k2；两只眼的中心点对不齐时调“镜片中心偏移”。")
                }

                Section("手势") {
                    Label("单指拖动：转视角", systemImage: "hand.draw")
                    Label("双指捏合：缩放", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("单屏：单击显隐控制条，双击暂停", systemImage: "hand.tap")
                    Label("分屏：单击暂停，双击退出分屏", systemImage: "eyeglasses")
                }
                .font(.footnote)
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Float>,
                           range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
