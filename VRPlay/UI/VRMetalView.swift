import SwiftUI
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

        let renderer = VRRenderer(view: view, session: session)
        context.coordinator.renderer = renderer
        view.delegate = renderer

        let c = context.coordinator
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

    final class Coordinator: NSObject {
        let session: PlayerSession
        var renderer: VRRenderer?
        var onSingleTap: () -> Void = {}
        var onDoubleTap: () -> Void = {}

        init(session: PlayerSession) { self.session = session }

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
