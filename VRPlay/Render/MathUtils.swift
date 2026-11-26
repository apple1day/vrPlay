import simd

extension simd_float4x4 {
    /// 由 3x3 旋转矩阵构造 4x4
    init(rotation m: simd_float3x3) {
        self.init(columns: (
            SIMD4<Float>(m.columns.0, 0),
            SIMD4<Float>(m.columns.1, 0),
            SIMD4<Float>(m.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1)))
    }
}

/// 绕 Y 轴旋转（逆时针，从上往下看）
func rotationY(_ a: Float) -> simd_float3x3 {
    let c = cos(a), s = sin(a)
    return simd_float3x3(columns: (
        SIMD3<Float>(c, 0, -s),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(s, 0, c)))
}

/// 绕 X 轴旋转（正值=抬头）
func rotationX(_ a: Float) -> simd_float3x3 {
    let c = cos(a), s = sin(a)
    return simd_float3x3(columns: (
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, c, s),
        SIMD3<Float>(0, -s, c)))
}

/// 右手系透视投影，Metal 深度范围 0…1
func perspectiveRH(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * near, 0)))
}

func translationMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, y, z, 1)
    return m
}

func scaleMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4<Float>(x, y, z, 1))
}
