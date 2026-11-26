import MetalKit
import CoreVideo
import simd

// 与 Shaders.metal 的 EyeUniforms 布局一致（128 字节）
struct EyeUniforms {
    var mvp = matrix_identity_float4x4
    var uvScale = SIMD2<Float>(1, 1)
    var uvOffset = SIMD2<Float>(0, 0)
    var uvInset = SIMD2<Float>(0, 0)
    var pad = SIMD2<Float>(0, 0)
    var yuvParams = SIMD4<Float>(0, 1, 0, 1)
    var yuvCoeffs = SIMD4<Float>(1.5748, 0.1873, 0.4681, 1.8556)
}

struct DistortUniforms {
    var p0 = SIMD4<Float>(0, 0, 0, 1)
    var p1 = SIMD4<Float>(1, 0, 0, 0)
}

private struct VideoFrame {
    let y: CVMetalTexture
    let c: CVMetalTexture
    let width: Int
    let height: Int
    let yuvParams: SIMD4<Float>
    let yuvCoeffs: SIMD4<Float>
}

/// 渲染流程（每帧）：
///  1. 从 PlayerCore 取最新 CVPixelBuffer → 零拷贝转 Y / CbCr 两张 Metal 纹理
///  2. 场景 pass：单屏画 1 次；分屏用两个 viewport 各画一次（每眼只采样视频的对应半幅）
///  3. 分屏且开启畸变时：场景先画到离屏纹理，再用全屏 pass 做镜片预畸变输出到屏幕
final class VRRenderer: NSObject, MTKViewDelegate {
    private let session: PlayerSession
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let sphereMesh: Mesh
    private let hemiMesh: Mesh
    private let quadMesh: Mesh
    private var textureCache: CVMetalTextureCache?
    private var offscreen: MTLTexture?
    private var current: VideoFrame?

    init?(view: MTKView, session: PlayerSession) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let sphere = MeshBuilder.sphere(device: device, hFov: 2 * .pi),
              let hemi = MeshBuilder.sphere(device: device, hFov: .pi),
              let quad = MeshBuilder.quad(device: device)
        else { return nil }

        func pipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let scene = pipeline("vr_vertex", "vr_fragment"),
              let post = pipeline("post_vertex", "post_fragment")
        else { return nil }

        self.session = session
        self.device = device
        self.queue = queue
        self.scenePipeline = scene
        self.postPipeline = post
        self.sphereMesh = sphere
        self.hemiMesh = hemi
        self.quadMesh = quad
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: 绘制

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        if let pb = session.player.copyLatestFrame(), let f = makeFrame(pb) { current = f }
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }

        let s = session.settings
        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        guard w > 0, h > 0 else { return }

        let split = s.displayMode == .split
        let usePost = split && (s.distortionEnabled || abs(s.lensOffset) > 0.0001)

        var target = drawable.texture
        if usePost, let off = offscreenTexture(w: w, h: h) { target = off }
        let renderedOffscreen = target !== drawable.texture

        // —— 场景 pass ——
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            if let frame = current { encodeScene(enc, settings: s, w: w, h: h, frame: frame) }
            enc.endEncoding()
        }

        // —— 畸变 pass ——
        if renderedOffscreen, let off = offscreen {
            let p2 = MTLRenderPassDescriptor()
            p2.colorAttachments[0].texture = drawable.texture
            p2.colorAttachments[0].loadAction = .dontCare
            p2.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: p2) {
                var du = DistortUniforms()
                let eyeAspect = Float(Double(w) / 2.0 / Double(h))
                let k1: Float = s.distortionEnabled ? s.k1 : 0
                let k2: Float = s.distortionEnabled ? s.k2 : 0
                du.p0 = SIMD4<Float>(k1, k2, s.lensOffset, eyeAspect)
                du.p1 = SIMD4<Float>(s.zoom, 0, 0, 0)
                enc.setRenderPipelineState(postPipeline)
                enc.setFragmentTexture(off, index: 0)
                enc.setFragmentBytes(&du, length: MemoryLayout<DistortUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cb.present(drawable)
        let keepAlive = current       // CVMetalTexture 必须活到 GPU 用完
        cb.addCompletedHandler { _ in _ = keepAlive }
        cb.commit()
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder, settings s: VRSettings,
                             w: Int, h: Int, frame: VideoFrame) {
        let split = s.displayMode == .split
        let eyeCount = split ? 2 : 1
        let eyeW = Double(w) / Double(eyeCount)
        let aspect = Float(eyeW / Double(h))

        let fovRad = s.fov * .pi / 180
        // 竖屏时 aspect < 1：把设置的 FOV 当作水平视场角
        let fovy: Float = aspect >= 1 ? fovRad : 2 * atan(tan(fovRad / 2) / aspect)
        let proj = perspectiveRH(fovy: fovy, aspect: aspect, near: 0.1, far: 50)
        let view = session.viewMatrix()

        var model = matrix_identity_float4x4
        let mesh: Mesh
        switch s.projection {
        case .sphere360:
            mesh = sphereMesh
        case .hemisphere180:
            mesh = hemiMesh
        case .flat:
            mesh = quadMesh
            model = flatModel(settings: s, frame: frame, fovy: fovy, aspect: aspect, split: split)
        }

        enc.setRenderPipelineState(scenePipeline)
        enc.setCullMode(.none)
        enc.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(frame.y), index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(frame.c), index: 1)

        let mvp = proj * view * model
        for eye in 0..<eyeCount {
            // 两眼视差已烘焙在视频里：相机朝向相同，只是采样的纹理区域不同
            let source = s.swapEyes ? 1 - eye : eye
            var u = EyeUniforms()
            u.mvp = mvp
            u.yuvParams = frame.yuvParams
            u.yuvCoeffs = frame.yuvCoeffs

            switch s.layout {
            case .mono:
                u.uvScale = SIMD2(1, 1); u.uvOffset = SIMD2(0, 0)
            case .sideBySide:
                u.uvScale = SIMD2(0.5, 1); u.uvOffset = SIMD2(0.5 * Float(source), 0)
            case .topBottom:
                u.uvScale = SIMD2(1, 0.5); u.uvOffset = SIMD2(0, 0.5 * Float(source))
            }
            u.uvInset = SIMD2(0.5 / (Float(frame.width) * u.uvScale.x),
                              0.5 / (Float(frame.height) * u.uvScale.y))

            enc.setViewport(MTLViewport(originX: eyeW * Double(eye), originY: 0,
                                        width: eyeW, height: Double(h), znear: 0, zfar: 1))
            enc.setVertexBytes(&u, length: MemoryLayout<EyeUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<EyeUniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
        }
    }

    /// 平面 / 虚拟影院：把单位平面缩放后放在正前方，单屏时按视口“适应”，分屏时留一点边
    private func flatModel(settings s: VRSettings, frame: VideoFrame,
                           fovy: Float, aspect: Float, split: Bool) -> simd_float4x4 {
        let w = Float(frame.width), h = Float(frame.height)
        var contentAspect: Float
        switch s.layout {
        case .mono:
            contentAspect = w / h
        case .sideBySide:
            contentAspect = (w / 2) / h
            if contentAspect < 1.2 { contentAspect = w / h }   // 半宽 SBS（每眼被压窄）还原
        case .topBottom:
            contentAspect = w / (h / 2)
            if contentAspect > 2.2 { contentAspect = w / h }   // 半高 TB 还原
        }

        let distance: Float = 3
        let halfH = distance * tan(fovy / 2)
        let halfW = halfH * aspect
        var width: Float, height: Float
        if contentAspect > aspect {
            width = 2 * halfW; height = width / contentAspect
        } else {
            height = 2 * halfH; width = height * contentAspect
        }
        let k = (split ? 0.75 : 1.0) * s.flatScale
        return translationMatrix(0, 0, -distance) * scaleMatrix(width * k, height * k, 1)
    }

    // MARK: 纹理

    private func offscreenTexture(w: Int, h: Int) -> MTLTexture? {
        if let t = offscreen, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        offscreen = device.makeTexture(descriptor: d)
        return offscreen
    }

    private func makeFrame(_ pb: CVPixelBuffer) -> VideoFrame? {
        guard let cache = textureCache, CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }

        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                  || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                     || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

        let w0 = CVPixelBufferGetWidthOfPlane(pb, 0), h0 = CVPixelBufferGetHeightOfPlane(pb, 0)
        let w1 = CVPixelBufferGetWidthOfPlane(pb, 1), h1 = CVPixelBufferGetHeightOfPlane(pb, 1)

        var yRef: CVMetalTexture?, cRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                  tenBit ? .r16Unorm : .r8Unorm, w0, h0, 0, &yRef)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                  tenBit ? .rg16Unorm : .rg8Unorm, w1, h1, 1, &cRef)
        guard let y = yRef, let c = cRef else { return nil }

        // 量化范围
        let params: SIMD4<Float>
        if fullRange {
            let half: Float = tenBit ? 512.0 / 1023.0 : 128.0 / 255.0
            params = SIMD4(0, 1, half, 1)
        } else if tenBit {
            params = SIMD4(64.0 / 1023.0, 1023.0 / 876.0, 512.0 / 1023.0, 1023.0 / 896.0)
        } else {
            params = SIMD4(16.0 / 255.0, 255.0 / 219.0, 128.0 / 255.0, 255.0 / 224.0)
        }

        // 色彩矩阵：优先读缓冲区附件，缺省时 HD 用 709、SD 用 601
        let name = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let coeffs: SIMD4<Float>
        if name == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            coeffs = SIMD4(1.4746, 0.1646, 0.5714, 1.8814)
        } else if name == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            coeffs = SIMD4(1.402, 0.3441, 0.7141, 1.772)
        } else if name == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) || h0 >= 720 {
            coeffs = SIMD4(1.5748, 0.1873, 0.4681, 1.8556)
        } else {
            coeffs = SIMD4(1.402, 0.3441, 0.7141, 1.772)
        }

        return VideoFrame(y: y, c: c, width: w0, height: h0, yuvParams: params, yuvCoeffs: coeffs)
    }
}
