import SwiftUI

struct PlayerView: View {
    let item: VideoItem

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = PlayerSession()
    @State private var showControls = true
    @State private var showSettings = false
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VRMetalView(session: session,
                        onSingleTap: handleSingleTap,
                        onDoubleTap: handleDoubleTap)
                .ignoresSafeArea()

            StatusOverlay(player: session.player)

            if showControls {
                ControlsView(session: session,
                             player: session.player,
                             title: item.title,
                             onClose: { dismiss() },
                             onSettings: { showSettings = true },
                             onInteraction: scheduleHide)
                    .transition(.opacity)
            }
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
            scheduleHide()
        }
        .onDisappear {
            session.close()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationManager.lock(.allButUpsideDown)
        }
        .onChange(of: showSettings) { open in
            if !open { scheduleHide() } else { hideWork?.cancel() }
        }
    }

    // 单屏：单击显示/隐藏控制条；分屏：单击暂停/播放（控制条在分屏里看不到）
    private func handleSingleTap() {
        if session.settings.displayMode == .split {
            session.player.togglePlay()
        } else {
            withAnimation { showControls.toggle() }
            if showControls { scheduleHide() }
        }
    }

    // 单屏：双击暂停/播放；分屏：双击退出分屏并显示控制条
    private func handleDoubleTap() {
        if session.settings.displayMode == .split {
            session.settings.displayMode = .single
            withAnimation { showControls = true }
            scheduleHide()
        } else {
            session.player.togglePlay()
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            if !showSettings, session.player.isPlaying {
                withAnimation { showControls = false }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

// MARK: - 缓冲 / 错误提示

private struct StatusOverlay: View {
    @ObservedObject var player: PlayerCore

    var body: some View {
        ZStack {
            if let err = player.errorText {
                Text(err)
                    .font(.callout)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            } else if player.isBuffering {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.4)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 控制条

private struct ControlsView: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var player: PlayerCore
    let title: String
    let onClose: () -> Void
    let onSettings: () -> Void
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
            Text(title).font(.headline).lineLimit(1)
            Spacer()
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

            Button(action: onSettings) { Image(systemName: "slider.horizontal.3").font(.title3) }
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
