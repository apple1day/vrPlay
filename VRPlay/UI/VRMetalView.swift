import SwiftUI
import AVFoundation
import MetalKit

/// 承载 MTKView，并处理手势：
///  单指拖动=转视角；双指捏合=缩放(FOV)；单击 / 双击回调给上层
struct VRMetalView: UIViewRepresentable {
    let session: PlayerSession
    var onSingleTap: () -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .black

        let c = context.coordinator
        do {
            let renderer = try VRRenderer(view: view, session: session)
            c.renderer = renderer
            view.delegate = renderer
        } catch {
            view.isPaused = true
            c.observeItemsAfterSetupFailure(error.localizedDescription)
        }

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.singleTap))
        singleTap.require(toFail: doubleTap)

        [pan, pinch, doubleTap, singleTap].forEach { view.addGestureRecognizer($0) }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.renderer = nil
        coordinator.setupFailureObserver = nil
    }

    final class Coordinator: NSObject {
        let session: PlayerSession
        var renderer: VRRenderer?
        var setupFailureObserver: NSKeyValueObservation?
        var onSingleTap: () -> Void = {}
        var onDoubleTap: () -> Void = {}

        init(session: PlayerSession) { self.session = session }

        // makeUIView can run before session.open or during a retry. Report setup failures
        // only after the active player item has been installed and its load state initialized.
        func observeItemsAfterSetupFailure(_ detail: String) {
            setupFailureObserver = session.player.player.observe(\.currentItem, options: [.initial, .new]) {
                [weak self] player, _ in
                guard let item = player.currentItem else { return }
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self, let item, item === self.session.player.player.currentItem,
                          self.setupFailureObserver != nil else { return }
                    self.session.player.reportRenderFailure("Metal 初始化失败：\(detail)")
                }
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            session.drag(dx: Float(t.x), dy: Float(t.y))
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            session.pinch(scale: Float(g.scale))
            g.scale = 1
        }
        @objc func singleTap() { onSingleTap() }
        @objc func doubleTap() { onDoubleTap() }
    }
}
