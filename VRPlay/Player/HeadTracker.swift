import CoreMotion
import UIKit
import simd

/// 头部追踪：把 CoreMotion 的姿态转换成“渲染世界系（Y 向上，-Z 为前）”下的相机旋转。
///
/// 推导：
///   CoreMotion 的 rotationMatrix R 把【参考系】向量变换到【设备系】(v_dev = R · v_ref)。
///   参考系取 xArbitraryZVertical（Z 向上），渲染世界系是 Y 向上，转换矩阵 C。
///   手机横屏放进头显后，相机的 右/上 轴在设备系里的方向取决于界面方向：
///       landscapeRight: right = -y_dev, up = +x_dev
///       landscapeLeft : right = +y_dev, up = -x_dev
///   相机朝向（渲染系） = C · Rᵀ · [right up back]
final class HeadTracker {
    private let motion = CMMotionManager()
    private(set) var isRunning = false

    func start() {
        guard !isRunning, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 90.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        isRunning = false
    }

    func headRotation(orientation: UIInterfaceOrientation) -> simd_float3x3? {
        guard let dm = motion.deviceMotion else { return nil }
        let m = dm.attitude.rotationMatrix
        // CMRotationMatrix 是行主序 m11…m33，simd 按列构造
        let R = simd_float3x3(columns: (
            SIMD3<Float>(Float(m.m11), Float(m.m21), Float(m.m31)),
            SIMD3<Float>(Float(m.m12), Float(m.m22), Float(m.m32)),
            SIMD3<Float>(Float(m.m13), Float(m.m23), Float(m.m33))))

        let right: SIMD3<Float>
        let up: SIMD3<Float>
        switch orientation {
        case .landscapeRight:
            right = SIMD3(0, -1, 0); up = SIMD3(1, 0, 0)
        case .landscapeLeft:
            right = SIMD3(0, 1, 0); up = SIMD3(-1, 0, 0)
        case .portraitUpsideDown:
            right = SIMD3(-1, 0, 0); up = SIMD3(0, -1, 0)
        default:
            right = SIMD3(1, 0, 0); up = SIMD3(0, 1, 0)
        }
        let back = simd_cross(right, up)
        let deviceFromCamera = simd_float3x3(columns: (right, up, back))

        // 参考系(Z 上) → 渲染系(Y 上)：x→x, z→y, y→-z
        let C = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, -1, 0)])

        return C * R.transpose * deviceFromCamera
    }
}
