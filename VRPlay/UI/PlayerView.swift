import AVFoundation
import SwiftUI

struct PlayerView: View {
    let item: VideoItem

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = PlayerSession()
    @State private var showControls = true
    @State private var showSettings = false
    @State private var hideWork: DispatchWorkItem?
    @State private var opened = false
    @State private var renderAttempt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if opened {
                PlaybackSurface(session: session, player: session.player, attempt: renderAttempt,
                                onSingleTap: handleSingleTap, onDoubleTap: handleDoubleTap)
                    .ignoresSafeArea()
            }

            if showControls {
                ControlsView(session: session,
                             player: session.player,
                             title: item.title,
                             onClose: { dismiss() },
                             onSettings: { showSettings = true },
                             onRetryVR: retryVR,
                             onInteraction: scheduleHide)
                    .transition(.opacity)
            }
            StatusOverlay(player: session.player, onRetry: retryVR)
            ProbeView(player: session.player).allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            OrientationManager.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            session.open(item)
            opened = true
            scheduleHide()
        }
        .onDisappear {
            hideWork?.cancel()
            opened = false
            session.close()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationManager.lock(.allButUpsideDown)
        }
        .onReceive(session.player.$errorText) { error in
            if error != nil { hideWork?.cancel(); showControls = true }
        }
        .onReceive(session.player.$hasPresentedVideo) { presented in
            if presented { scheduleHide() }
        }
        .onChange(of: showSettings) { open in
            if !open { scheduleHide() } else { hideWork?.cancel() }
        }
    }

    // 单屏：单击显示/隐藏控制条；分屏：单击暂停/播放（控制条在分屏里看不到）
    private func handleSingleTap() {
        if !session.player.usesSystemDisplay && session.settings.displayMode == .split {
            session.player.togglePlay()
        } else {
            withAnimation { showControls.toggle() }
            if showControls { scheduleHide() }
        }
    }

    // 单屏：双击暂停/播放；分屏：双击退出分屏并显示控制条
    private func handleDoubleTap() {
        if !session.player.usesSystemDisplay && session.settings.displayMode == .split {
            session.settings.displayMode = .single
            withAnimation { showControls = true }
            scheduleHide()
        } else {
            session.player.togglePlay()
        }
    }

    private func retryVR() {
        showControls = true
        renderAttempt += 1
        session.player.retry()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            if !showSettings, session.player.isPlaying, session.player.hasPresentedVideo,
               session.player.errorText == nil {
                withAnimation { showControls = false }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

private struct ProbeView: View {
    @ObservedObject var player: PlayerCore
    var body: some View {
        VStack { Spacer()
            Text(player.probeResult).font(.system(size: 5)).accessibilityIdentifier("vrplay.pixels")
        }
    }
}

private struct PlaybackSurface: View {
    let session: PlayerSession
    @ObservedObject var player: PlayerCore
    let attempt: Int
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        if player.usesSystemDisplay {
            SystemPlayerSurface(player: player)
                .id(player.videoGeneration)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { onDoubleTap() }
                    .exclusively(before: TapGesture().onEnded { onSingleTap() }))
        } else {
            VRMetalView(session: session, onSingleTap: onSingleTap, onDoubleTap: onDoubleTap)
                .id(attempt)
        }
    }
}

private struct SystemPlayerSurface: UIViewRepresentable {
    let player: PlayerCore

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var observation: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        let layer = view.playerLayer
        layer.videoGravity = .resizeAspect
        layer.player = player.player
        let generation = player.videoGeneration
        view.observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak player] layer, _ in
            DispatchQueue.main.async {
                guard let player, player.videoGeneration == generation, player.usesSystemDisplay,
                      layer.player === player.player, layer.isReadyForDisplay else { return }
                player.didPresentSystemFrame()
            }
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.observation?.invalidate()
        view.playerLayer.player = nil
    }
}

private struct StatusOverlay: View {
    @ObservedObject var player: PlayerCore
    let onRetry: () -> Void

    var body: some View {
        if let error = player.errorText {
            VStack(spacing: 8) {
                Text(error)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("playback.error")
                HStack {
                    Button("重试 VR", action: onRetry)
                    if !player.usesSystemDisplay {
                        Button("系统平面播放") { player.useSystemDisplay() }
                    }
                    Button("复制错误") { UIPasteboard.general.string = error }
                }
                .buttonStyle(.bordered)
            }
            .foregroundColor(.white)
            .padding(12)
            .frame(maxWidth: 520)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        } else if let message = player.startupMessage {
            ProgressView(message).tint(.white)
                .foregroundColor(.white)
                .allowsHitTesting(false)
        } else if player.isBuffering {
            ProgressView("缓冲中…").tint(.white)
                .foregroundColor(.white)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 控制条

private struct ControlsView: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var player: PlayerCore
    let title: String
    let onClose: () -> Void
    let onSettings: () -> Void
    let onRetryVR: () -> Void
    let onInteraction: () -> Void

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .foregroundColor(.white)
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button(action: onClose) { Image(systemName: "xmark").font(.title3) }
                .accessibilityLabel("关闭播放")
                .accessibilityIdentifier("playback.close")
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            if player.usesSystemDisplay {
                Button("返回 VR", action: onRetryVR)
            } else {
                Button {
                    session.recenter(); onInteraction()
                } label: { Image(systemName: "scope").font(.title3) }

                Button {
                    session.settings.displayMode = (session.settings.displayMode == .split) ? .single : .split
                    onInteraction()
                } label: {
                    Image(systemName: session.settings.displayMode == .split ? "eyeglasses" : "rectangle")
                        .font(.title3)
                        .padding(6)
                        .background(session.settings.displayMode == .split ? Color.accentColor : .clear, in: Circle())
                }
                .accessibilityLabel(session.settings.displayMode == .split ? "退出 VR 分屏" : "进入 VR 分屏")
                .accessibilityIdentifier("playback.split")

                Button(action: onSettings) { Image(systemName: "slider.horizontal.3").font(.title3) }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { player.skip(by: -10); onInteraction() } label: { Image(systemName: "gobackward.10").font(.title2) }
            Button { player.togglePlay(); onInteraction() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                    .frame(width: 30)
            }
            Button { player.skip(by: 10); onInteraction() } label: { Image(systemName: "goforward.10").font(.title2) }

            Text(format(scrubbing ? scrubValue : player.currentTime))
                .font(.caption.monospacedDigit())

            Slider(
                value: Binding(get: { scrubbing ? scrubValue : player.currentTime },
                               set: { scrubValue = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: scrubValue) }
                    onInteraction()
                })

            Text(format(player.duration)).font(.caption.monospacedDigit())
        }
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
