import SwiftUI
@preconcurrency import MetalKit
import OSLog

/// The central engine for Gemma PBR.
/// Manages GPU state and standardized image ingestion for compute-heavy PBR workflows.
@Observable
@MainActor
final class TextureGenerator {
    // MARK: - Metal Core
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let logger = Logger(subsystem: "com.gemma.pbr", category: "TextureGenerator")
    
    // MARK: - State
    var sourceTexture: MTLTexture?
    var sourceImage: NSImage?
    var outputTexture: MTLTexture?
    var normalTexture: MTLTexture?
    var seamlessTexture: MTLTexture?
    var roughnessTexture: MTLTexture?
    var metallicTexture: MTLTexture?
    var aoTexture: MTLTexture?
    
    var isProcessing: Bool = false
    var redrawTrigger: Int = 0
    var tileCount: Float = 2.0
    var normalStrength: Float = 5.0
    var rotationAngle: Float = 0.0
    var panOffset: CGPoint = .zero
    var seamlessStrength: Float = 0.1
    var roughnessMin: Float = 0.2
    var roughnessMax: Float = 0.9
    var metallicMin: Float = 0.0
    var metallicMax: Float = 0.3
    var aoStrength: Float = 1.0
    enum LightingRig: String, CaseIterable, Identifiable {
        case studio  = "Studio"
        case softbox = "Softbox"
        case row     = "Row"
        var id: String { rawValue }
    }
    var lightingRig: LightingRig = .studio

    enum FloorStyle: String, CaseIterable, Identifiable {
        case reflective = "Reflective"
        case matte      = "Matte"
        var id: String { rawValue }
    }
    var floorStyle: FloorStyle = .reflective

    enum IBLPreset: String, CaseIterable, Identifiable {
        case neutralStudio = "Studio"
        case productWhite  = "Product"
        case overcast      = "Overcast"
        case golden        = "Golden"
        case coolBlue      = "Cool"
        var id: String { rawValue }
    }
    var iblPreset:   IBLPreset = .neutralStudio
    var iblRotation: Float     = 0.0
    var floorColor: Color = Color(white: 0.65)
    var domeColor: Color  = Color(white: 0.86)
    var cameraAzimuth: Float   = 45.0
    var cameraElevation: Float = 20.0
    var lightAzimuth: Float = 45.0
    var lightElevation: Float = 35.0
    var lightIntensity: Float = 1500.0
    var lightTemperature: Float = 6500.0
    var lightColor: Color = .white
    var fillLightIntensity: Float = 500.0
    var rimLightIntensity: Float  = 200.0
    var underLightEnabled: Bool    = false
    var underLightIntensity: Float = 3000.0
    var underLightSpread: Float    = 70.0
    var underLightColor: Color     = .white
    var bounceLightIntensity: Float = 1.0
    var ballTextureScale: Float = 1.0
    var ballTextureOffsetX: Float = 0.0
    var ballTextureOffsetY: Float = 0.0
    var ballTextureRotation: Float = 0.0
    var applyToBallTrigger: Int = 0
    var refocusTrigger: Int = 0
    var cameraFillEnabled: Bool    = true
    var cameraFillIntensity: Float = 300.0
    var cameraFillColor: Color     = .white
    var ringLightEnabled: Bool     = false
    var ringLightIntensity: Float  = 800.0
    var ringLightRadius: Float     = 0.3
    var ringLightColor: Color      = .white
    var showLightGizmos: Bool      = false

    func applyTexturesToBall() { applyToBallTrigger &+= 1 }
    func refocusCamera()       { refocusTrigger &+= 1 }

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device.")
        }
        self.device = device
        
        guard let queue = device.makeCommandQueue() else {
            fatalError("Could not create Metal command queue.")
        }
        self.commandQueue = queue
    }

    func ingest(image: NSImage) async {
        self.isProcessing = true
        self.sourceImage = image
        if let texture = self.processImageTo1024Texture(image) {
            self.sourceTexture = texture
            self.outputTexture = self.makeEmptyTexture()
            self.normalTexture = self.makeEmptyTexture()
            self.seamlessTexture = self.makeEmptyTexture()
            self.roughnessTexture = self.makeEmptyTexture()
            self.metallicTexture = self.makeEmptyTexture()
            self.aoTexture = self.makeEmptyTexture()
            
            // Auto-bake all maps for live preview
            bakeNormalMap()
            bakeRoughnessMap()
            bakeMetallicMap()
            bakeAOMap()
        }
        self.isProcessing = false
    }

    /// Generates a seamless version of the source texture.
    func applySeamlessFix() {
        guard let source = sourceTexture, let target = seamlessTexture else { return }
        isProcessing = true
        
        runComputeKernel(name: "makeItTileKernel") { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&seamlessStrength, length: MemoryLayout<Float>.size, index: 0)
        }
        
        // After making it seamless, we should use the seamless texture as the new source for normals
        self.sourceTexture = target
    }

    func bakeNormalMap() {
        guard let source = sourceTexture, let normal = normalTexture else { return }
        isProcessing = true
        
        runComputeKernel(name: "sobelNormalKernel") { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(normal, index: 1)
            encoder.setBytes(&normalStrength, length: MemoryLayout<Float>.size, index: 0)
        }
    }

    func bakeRoughnessMap() {
        guard let source = sourceTexture, let target = roughnessTexture else { return }
        isProcessing = true

        runComputeKernel(name: "pbrMapKernel") { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&roughnessMin, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&roughnessMax, length: MemoryLayout<Float>.size, index: 1)
        }
    }

    func bakeMetallicMap() {
        guard let source = sourceTexture, let target = metallicTexture else { return }
        isProcessing = true

        runComputeKernel(name: "pbrMapKernel") { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&metallicMin, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&metallicMax, length: MemoryLayout<Float>.size, index: 1)
        }
    }

    func bakeAOMap() {
        guard let source = sourceTexture, let target = aoTexture else { return }
        isProcessing = true

        runComputeKernel(name: "aoKernel") { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&aoStrength, length: MemoryLayout<Float>.size, index: 0)
        }
    }

    // MARK: - Helper Methods
    
    private func runComputeKernel(name: String, encoding: (MTLComputeCommandEncoder) -> Void) {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: name) else {
            isProcessing = false
            return
        }
        
        do {
            let pipelineState = try device.makeComputePipelineState(function: function)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                isProcessing = false
                return
            }
            
            encoder.setComputePipelineState(pipelineState)
            encoding(encoder)
            
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadsPerGrid = MTLSize(width: 1024, height: 1024, depth: 1)
            
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            
            commandBuffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.redrawTrigger &+= 1
                }
            }
            commandBuffer.commit()
            
        } catch {
            logger.error("Failed to run kernel \(name): \(error.localizedDescription)")
            isProcessing = false
        }
    }

    private func processImageTo1024Texture(_ image: NSImage) -> MTLTexture? {
        let size = CGSize(width: 1024, height: 1024)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let rawData = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1024, height: 1024, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let region = MTLRegionMake2D(0, 0, 1024, 1024)
        texture.replace(region: region, mipmapLevel: 0, withBytes: rawData, bytesPerRow: 1024 * 4)
        return texture
    }
    
    private func makeEmptyTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1024, height: 1024, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
