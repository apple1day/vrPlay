import MetalKit
import UIKit
import CoreVideo
import simd

// 与 Shaders.metal 的 EyeUniforms 布局一致（128 字节）
struct EyeUniforms {
    var mvp = matrix_identity_float4x4
    var uvScale = SIMD2<Float>(1, 1)
    var uvOffset = SIMD2<Float>(0, 0)
    var uvInset = SIMD2<Float>(0, 0)
    var packedRGB: UInt32 = 0
    var pad: UInt32 = 0
    var yuvParams = SIMD4<Float>(0, 1, 0, 1)
    var yuvCoeffs = SIMD4<Float>(1.5748, 0.1873, 0.4681, 1.8556)
}

struct DistortUniforms {
    var p0 = SIMD4<Float>(0, 0, 0, 1)
    var p1 = SIMD4<Float>(1, 0, 0, 0)
}

private struct VideoFrame {
    let buffer: CVPixelBuffer
    let color: CVMetalTexture
    let chroma: CVMetalTexture?
    let width: Int
    let height: Int
    let yuvParams: SIMD4<Float>
    let yuvCoeffs: SIMD4<Float>
}

private struct RenderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
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
    private let textureCache: CVMetalTextureCache
    private var offscreen: MTLTexture?
    private var current: VideoFrame?

    private var generation: UUID?
    private var presentedGeneration: UUID?
    private var failedGeneration: UUID?

    init(view: MTKView, session: PlayerSession) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RenderError("设备无法创建 Metal 渲染队列")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let sphere = MeshBuilder.sphere(device: device, hFov: 2 * .pi),
              let hemi = MeshBuilder.sphere(device: device, hFov: .pi),
              let quad = MeshBuilder.quad(device: device) else {
            throw RenderError("无法分配 VR 投影网格")
        }

        func pipeline(_ vs: String, _ fs: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            guard let vertex = library.makeFunction(name: vs),
                  let fragment = library.makeFunction(name: fs) else {
                throw RenderError("着色器缺失：\(vs) / \(fs)")
            }
            d.vertexFunction = vertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let scene = try pipeline("vr_vertex", "vr_fragment")
        let post = try pipeline("post_vertex", "post_fragment")
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw RenderError("无法创建视频纹理缓存（Core Video \(status)）")
        }

        self.textureCache = cache
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
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: 绘制

    func draw(in view: MTKView) {
        guard view.window != nil, UIApplication.shared.applicationState != .background else { return }
        let player = session.player
        let generation = player.videoGeneration
        if self.generation != generation {
            self.generation = generation
            current = nil
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        guard failedGeneration != generation else { return }
        if let pb = player.copyLatestFrame() {
            do {
                current = try makeFrame(pb)
            } catch {
                // Restart output negotiation once before offering system playback.
                failedGeneration = generation
                player.videoTextureFailed(error.localizedDescription)
                return
            }
        }

        guard let drawable = view.currentDrawable else { return }
        guard let cb = queue.makeCommandBuffer() else {
            fail("无法创建 Metal 命令缓冲区", generation: generation)
            return
        }
        let s = session.settings
        let w = drawable.texture.width, h = drawable.texture.height
        let usePost = current != nil && s.displayMode == .split
            && (s.distortionEnabled || abs(s.lensOffset) > 0.0001)
        let intermediate = usePost ? offscreenTexture(w: w, h: h) : nil
        let target = intermediate ?? drawable.texture

        // —— 场景 pass ——
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let sceneEncoder = cb.makeRenderCommandEncoder(descriptor: pass) else {
            fail("无法创建场景渲染命令", generation: generation)
            return
        }
        if let frame = current { encodeScene(sceneEncoder, settings: s, w: w, h: h, frame: frame) }
        sceneEncoder.endEncoding()

        // —— 畸变 pass ——
        if let off = intermediate {
            let p2 = MTLRenderPassDescriptor()
            p2.colorAttachments[0].texture = drawable.texture
            p2.colorAttachments[0].loadAction = .dontCare
            p2.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: p2) else {
                fail("无法创建镜片校正渲染命令", generation: generation)
                return
            }
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

        if current != nil, presentedGeneration != generation {
            let markFrameVisible = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.session.player.videoGeneration == generation,
                          self.presentedGeneration != generation, self.failedGeneration != generation else { return }
                    self.presentedGeneration = generation
                    self.session.player.didPresentVideoFrame()
                }
            }
            #if targetEnvironment(simulator)
            // Simulator SDKs do not expose MTLDrawable's presentation timestamp.
            // UI tests independently check the final window pixels.
            cb.addCompletedHandler { completed in
                if completed.status == .completed { markFrameVisible() }
            }
            #else
            drawable.addPresentedHandler { shown in
                if shown.presentedTime > 0 { markFrameVisible() }
            }
            #endif
        }
        cb.present(drawable)
        // Keep the pixel buffer and Core Video texture wrappers alive until this draw finishes.
        cb.addCompletedHandler { [weak self, frame = current] completed in
            withExtendedLifetime(frame) {}
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "GPU 未完成渲染"
                DispatchQueue.main.async {
                    guard UIApplication.shared.applicationState != .background else { return }
                    self?.fail(message, generation: generation)
                }
            }
        }
        cb.commit()
    }

    private func fail(_ message: String, generation: UUID) {
        guard generation == session.player.videoGeneration, failedGeneration != generation else { return }
        failedGeneration = generation
        current = nil
        session.player.reportRenderFailure(message)
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
        enc.setFragmentTexture(CVMetalTextureGetTexture(frame.color), index: 0)
        enc.setFragmentTexture(CVMetalTextureGetTexture(frame.chroma ?? frame.color), index: 1)

        let mvp = proj * view * model
        for eye in 0..<eyeCount {
            // 两眼视差已烘焙在视频里：相机朝向相同，只是采样的纹理区域不同
            let source = s.swapEyes ? 1 - eye : eye
            var u = EyeUniforms()
            u.mvp = mvp
            u.packedRGB = frame.chroma == nil ? 1 : 0
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

    private func makeFrame(_ pb: CVPixelBuffer) throws -> VideoFrame {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let format = String(format: "%08X", fmt)

        func texture(_ plane: Int, _ pixelFormat: MTLPixelFormat, _ w: Int, _ h: Int) throws -> CVMetalTexture {
            var ref: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb,
                                                                  nil, pixelFormat, w, h, plane, &ref)
            guard status == kCVReturnSuccess, let ref, CVMetalTextureGetTexture(ref) != nil else {
                throw RenderError("视频纹理转换失败：\(width)×\(height)，格式 0x\(format)，平面 \(plane)，Core Video \(status)")
            }
            return ref
        }

        if fmt == kCVPixelFormatType_32BGRA {
            let color = try texture(0, .bgra8Unorm, width, height)
            return VideoFrame(buffer: pb, color: color, chroma: nil, width: width, height: height,
                              yuvParams: .zero, yuvCoeffs: .zero)
        }

        let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                  || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let eightBit = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard tenBit || eightBit, CVPixelBufferGetPlaneCount(pb) == 2 else {
            throw RenderError("暂不支持视频像素格式 0x\(format)（\(width)×\(height)）")
        }
        let fullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                     || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let y = try texture(0, tenBit ? .r16Unorm : .r8Unorm,
                            CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0))
        let c = try texture(1, tenBit ? .rg16Unorm : .rg8Unorm,
                            CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1))

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
        } else if name == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) || height >= 720 {
            coeffs = SIMD4(1.5748, 0.1873, 0.4681, 1.8556)
        } else {
            coeffs = SIMD4(1.402, 0.3441, 0.7141, 1.772)
        }

        return VideoFrame(buffer: pb, color: y, chroma: c, width: width, height: height,
                          yuvParams: params, yuvCoeffs: coeffs)
    }
}
