import Metal

struct Mesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
}

/// 顶点格式：x y z u v（5 个 Float，stride 20），对应 Shaders.metal 里的 packed_float3 + packed_float2
enum MeshBuilder {

    /// 球面网格。观察者在球心，贴图贴在内侧。
    /// hFov = 2π → 360° 整球；hFov = π → VR180 半球（垂直方向始终 180°）。
    static func sphere(device: MTLDevice, rings: Int = 64, segments: Int = 128,
                       hFov: Float = 2 * .pi, radius: Float = 10) -> Mesh? {
        var verts: [Float] = []
        verts.reserveCapacity((rings + 1) * (segments + 1) * 5)
        for r in 0...rings {
            let v = Float(r) / Float(rings)
            let phi = v * .pi                         // 0(顶) … π(底)
            for s in 0...segments {
                let u = Float(s) / Float(segments)
                let theta = (u - 0.5) * hFov          // 以正前方(-Z)为 0
                let x = sin(phi) * sin(theta)
                let y = cos(phi)
                let z = -sin(phi) * cos(theta)
                verts += [x * radius, y * radius, z * radius, u, v]
            }
        }
        var idx: [UInt32] = []
        let stride = segments + 1
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt32(r * stride + s)
                let b = a + UInt32(stride)
                idx += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return make(device: device, vertices: verts, indices: idx)
    }

    /// 单位平面（宽高均为 1，中心在原点），用模型矩阵缩放摆放
    static func quad(device: MTLDevice) -> Mesh? {
        let verts: [Float] = [
            -0.5,  0.5, 0, 0, 0,
             0.5,  0.5, 0, 1, 0,
            -0.5, -0.5, 0, 0, 1,
             0.5, -0.5, 0, 1, 1
        ]
        return make(device: device, vertices: verts, indices: [0, 2, 1, 1, 2, 3])
    }

    private static func make(device: MTLDevice, vertices: [Float], indices: [UInt32]) -> Mesh? {
        guard let vb = device.makeBuffer(bytes: vertices,
                                         length: vertices.count * MemoryLayout<Float>.stride,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices,
                                         length: indices.count * MemoryLayout<UInt32>.stride,
                                         options: .storageModeShared)
        else { return nil }
        return Mesh(vertexBuffer: vb, indexBuffer: ib, indexCount: indices.count)
    }
}
