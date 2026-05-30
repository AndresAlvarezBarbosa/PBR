import SwiftUI
import MetalKit

struct MainView: View {
    @State private var generator = TextureGenerator()
    @State private var selectedMap: PBRMap = .diffuse
    @State private var displayMode: DisplayMode = .maps2D

    enum PBRMap: String, CaseIterable, Identifiable {
        case diffuse = "Diffuse"
        case normal = "Normal"
        case roughness = "Roughness"
        case metallic = "Metallic"
        case ao = "AO"
        var id: String { self.rawValue }
    }
    
    enum DisplayMode: String, CaseIterable, Identifiable {
        case maps2D = "2D Maps"
        case preview3D = "3D Preview"
        var id: String { self.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            // SIDEBAR: Controls
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Gemma PBR")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            resetAll()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear All Settings & Textures")
                    }
                    .padding(.bottom, 10)
                    
                    Divider()
                    
                    // SECTION: Base Color (Albedo)
                    Group {
                        Label("Base Color (Albedo)", systemImage: "photo.fill")
                            .font(.headline)
                        
                        ImageIngestView(generator: generator)
                    }
                    
                    Divider()
                    
                    // SECTION: 2D Visualization
                    if displayMode == .maps2D {
                        Group {
                            HStack {
                                Label("Visualization", systemImage: "eye.fill")
                                    .font(.headline)
                                Spacer()
                                Button("Reset") {
                                    generator.tileCount = 2.0
                                    generator.rotationAngle = 0
                                    generator.panOffset = .zero
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            
                            Picker("Active Map", selection: $selectedMap) {
                                ForEach(PBRMap.allCases) { map in
                                    Text(map.rawValue).tag(map)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Tiling:")
                                    Spacer()
                                    Text("\(Int(generator.tileCount))x")
                                        .monospacedDigit()
                                }
                                Slider(value: $generator.tileCount, in: 1...10, step: 1)
                            }
                            
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text("Rotation:")
                                    Text("\(Int(generator.rotationAngle))°")
                                        .monospacedDigit()
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                RotationDial(angle: $generator.rotationAngle)
                                    .frame(width: 64, height: 64)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // SECTION: Seamlessness
                    Group {
                        HStack {
                            Label("Make It Tile", systemImage: "square.grid.3x3.fill")
                                .font(.headline)
                            Spacer()
                            Button("Reset") { generator.seamlessStrength = 0.1 }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Blend Range:")
                                Spacer()
                                Text(String(format: "%.2f", generator.seamlessStrength))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.seamlessStrength, in: 0.01...0.3)
                        }
                        
                        Button(action: {
                            generator.applySeamlessFix()
                        }) {
                            Label("Apply Seamless Fix", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(generator.sourceTexture == nil || generator.isProcessing)
                    }
                    
                    Divider()
                    
                    // SECTION: Normal Map
                    Group {
                        HStack {
                            Label("Normal Map", systemImage: "m.square.fill")
                                .font(.headline)
                            Spacer()
                            Button("Reset") { generator.normalStrength = 5.0 }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        
                        HStack {
                            Text("Strength:")
                            Slider(value: $generator.normalStrength, in: 0.1...20.0)
                        }
                        
                        Button(action: {
                            generator.bakeNormalMap()
                            selectedMap = .normal
                        }) {
                            Label("Bake Normal Map", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(generator.sourceTexture == nil || generator.isProcessing)
                    }
                    
                    Divider()
                    
                    // SECTION: Roughness Map
                    Group {
                        HStack {
                            Label("Roughness Map", systemImage: "r.square.fill")
                                .font(.headline)
                            Spacer()
                            Button("Reset") {
                                generator.roughnessMin = 0.2
                                generator.roughnessMax = 0.9
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min:")
                                Spacer()
                                Text(String(format: "%.2f", generator.roughnessMin))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.roughnessMin, in: 0.0...1.0)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Max:")
                                Spacer()
                                Text(String(format: "%.2f", generator.roughnessMax))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.roughnessMax, in: 0.0...1.0)
                        }
                        
                        Button(action: {
                            generator.bakeRoughnessMap()
                            selectedMap = .roughness
                        }) {
                            Label("Bake Roughness Map", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(generator.sourceTexture == nil || generator.isProcessing)
                    }
                    
                    Divider()
                    
                    // SECTION: Metallic Map
                    Group {
                        HStack {
                            Label("Metallic Map", systemImage: "circle.hexagongrid.fill")
                                .font(.headline)
                            Spacer()
                            Button("Reset") {
                                generator.metallicMin = 0.0
                                generator.metallicMax = 0.3
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min:")
                                Spacer()
                                Text(String(format: "%.2f", generator.metallicMin))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.metallicMin, in: 0.0...1.0)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Max:")
                                Spacer()
                                Text(String(format: "%.2f", generator.metallicMax))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.metallicMax, in: 0.0...1.0)
                        }
                        
                        Button(action: {
                            generator.bakeMetallicMap()
                            selectedMap = .metallic
                        }) {
                            Label("Bake Metallic Map", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(generator.sourceTexture == nil || generator.isProcessing)
                    }
                    
                    Divider()
                    
                    // 3D-specific controls now live inside the 3D viewport as a
                    // floating panel — see Preview3DControls below.
                    
                    Divider()
                    
                    // SECTION: Ambient Occlusion Map
                    Group {
                        HStack {
                            Label("AO Map", systemImage: "moon.stars.fill")
                                .font(.headline)
                            Spacer()
                            Button("Reset") { generator.aoStrength = 1.0 }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Strength:")
                                Spacer()
                                Text(String(format: "%.2f", generator.aoStrength))
                                    .monospacedDigit()
                            }
                            Slider(value: $generator.aoStrength, in: 0.1...3.0)
                        }
                        
                        Button(action: {
                            generator.bakeAOMap()
                            selectedMap = .ao
                        }) {
                            Label("Bake AO Map", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(generator.sourceTexture == nil || generator.isProcessing)
                    }
                    
                }
                .padding()
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 380, max: 460)
            .onChange(of: generator.normalStrength) { _, _ in
                generator.bakeNormalMap()
            }
            .onChange(of: generator.roughnessMin) { _, _ in
                generator.bakeRoughnessMap()
            }
            .onChange(of: generator.roughnessMax) { _, _ in
                generator.bakeRoughnessMap()
            }
            .onChange(of: generator.metallicMin) { _, _ in
                generator.bakeMetallicMap()
            }
            .onChange(of: generator.metallicMax) { _, _ in
                generator.bakeMetallicMap()
            }
            .onChange(of: generator.aoStrength) { _, _ in
                generator.bakeAOMap()
            }
        } detail: {
            // DETAIL: Visualization
            VStack(spacing: 0) {
                // Top tab bar to switch between 2D and 3D
                Picker("Display Mode", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                
                ZStack {
                    (displayMode == .preview3D ? Color.white : Color.black)
                        .ignoresSafeArea()
                    
                    if displayMode == .preview3D {
                        PreviewView3D(
                            generator: generator,
                            redrawTrigger: generator.redrawTrigger,
                            applyTrigger: generator.applyToBallTrigger,
                            sourceImageID: generator.sourceImage.map { ObjectIdentifier($0) },
                            refocusTrigger: generator.refocusTrigger,
                            floorStyle: generator.floorStyle,
                            cameraAzimuth: generator.cameraAzimuth,
                            cameraElevation: generator.cameraElevation,
                            floorColor: generator.floorColor,
                            domeColor: generator.domeColor,
                            iblPreset: generator.iblPreset,
                            iblRotation: generator.iblRotation,
                            lightingRig: generator.lightingRig,
                            lightIntensity: generator.lightIntensity,
                            bounceLightIntensity: generator.bounceLightIntensity,
                            fillLightIntensity: generator.fillLightIntensity,
                            rimLightIntensity: generator.rimLightIntensity,
                            cameraFillEnabled: generator.cameraFillEnabled,
                            cameraFillIntensity: generator.cameraFillIntensity,
                            ringLightEnabled: generator.ringLightEnabled,
                            ringLightIntensity: generator.ringLightIntensity,
                            underLightEnabled: generator.underLightEnabled,
                            underLightIntensity: generator.underLightIntensity,
                            showLightGizmos: generator.showLightGizmos,
                            ballTextureScale: generator.ballTextureScale,
                            ballTextureOffsetX: generator.ballTextureOffsetX,
                            ballTextureOffsetY: generator.ballTextureOffsetY,
                            ballTextureRotation: generator.ballTextureRotation,
                            lightColor: generator.lightColor,
                            lightTemperature: generator.lightTemperature,
                            underLightSpread: generator.underLightSpread,
                            underLightColor: generator.underLightColor,
                            cameraFillColor: generator.cameraFillColor,
                            ringLightColor: generator.ringLightColor
                        )
                        .overlay(alignment: .leading) {
                            Preview3DControls(generator: generator)
                                .frame(width: 300)
                                .frame(maxHeight: 700)
                                .padding(20)
                        }
                    } else if let textureToDisplay = currentTexture {
                        TilingMetalView(
                            texture: textureToDisplay,
                            tileCount: generator.tileCount,
                            rotation: generator.rotationAngle,
                            offset: generator.panOffset,
                            redrawTrigger: generator.redrawTrigger,
                            device: generator.device
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .padding(40)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    generator.panOffset.x += value.translation.width / 500
                                    generator.panOffset.y += value.translation.height / 500
                                }
                        )
                    } else {
                        ContentUnavailableView(
                            "No Texture Loaded",
                            systemImage: "photo.badge.plus",
                            description: Text("Drag and drop a texture into the sidebar to begin.")
                        )
                    }
                    
                    if generator.isProcessing {
                        VStack {
                            ProgressView()
                                .controlSize(.large)
                            Text("GPU Baking in Progress...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                }
            }
        }
    }
    
    private var currentTexture: MTLTexture? {
        switch selectedMap {
        case .diffuse: return generator.sourceTexture
        case .normal: return generator.normalTexture
        case .roughness: return generator.roughnessTexture
        case .metallic: return generator.metallicTexture
        case .ao: return generator.aoTexture
        }
    }
    
    private func resetAll() {
        generator.tileCount = 2.0
        generator.rotationAngle = 0
        generator.panOffset = .zero
        generator.normalStrength = 5.0
        generator.seamlessStrength = 0.1
        generator.roughnessMin = 0.2
        generator.roughnessMax = 0.9
        generator.metallicMin = 0.0
        generator.metallicMax = 0.3
        generator.aoStrength = 1.0
        generator.lightAzimuth = 45
        generator.lightElevation = 35
        generator.lightIntensity = 1500
        generator.lightTemperature = 6500
        generator.lightColor = .white
        generator.bounceLightIntensity = 1.0
        generator.iblPreset            = .neutralStudio
        generator.iblRotation          = 0
        generator.cameraFillEnabled    = true
        generator.cameraFillIntensity  = 300.0
        generator.cameraFillColor      = .white
        generator.ringLightEnabled     = false
        generator.ringLightIntensity   = 800.0
        generator.ringLightRadius      = 0.3
        generator.ringLightColor       = .white
        generator.showLightGizmos      = false
        generator.ballTextureScale = 1.0
        generator.ballTextureOffsetX = 0.0
        generator.ballTextureOffsetY = 0.0
        generator.ballTextureRotation = 0.0
        generator.floorStyle = .reflective
        generator.cameraAzimuth   = 45
        generator.cameraElevation = 20
        generator.floorColor = Color(white: 0.38)
        generator.domeColor  = Color(red: 0.92, green: 0.90, blue: 0.87)
        generator.sourceTexture = nil
        generator.sourceImage = nil
        generator.normalTexture = nil
        generator.seamlessTexture = nil
        generator.roughnessTexture = nil
        generator.metallicTexture = nil
        generator.aoTexture = nil
        selectedMap = .diffuse
        displayMode = .maps2D
    }
}

// MARK: - Metal Visualization View
struct TilingMetalView: NSViewRepresentable {
    let texture: MTLTexture
    let tileCount: Float
    let rotation: Float
    let offset: CGPoint
    let redrawTrigger: Int
    let device: MTLDevice

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = device
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.drawableSize = CGSize(width: 1024, height: 1024)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.texture = texture
        context.coordinator.tileCount = tileCount
        context.coordinator.rotation = rotation
        context.coordinator.offset = offset
        nsView.draw()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var texture: MTLTexture?
        var tileCount: Float = 1.0
        var rotation: Float = 0.0
        var offset: CGPoint = .zero
        let commandQueue: MTLCommandQueue?
        let pipelineState: MTLRenderPipelineState?

        init(device: MTLDevice) {
            self.commandQueue = device.makeCommandQueue()
            
            let library = device.makeDefaultLibrary()
            let vertexFunction = library?.makeFunction(name: "tilingVertex")
            let fragmentFunction = library?.makeFunction(name: "tilingFragment")
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            self.pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pipelineState = pipelineState,
                  let texture = texture,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
            encoder?.setRenderPipelineState(pipelineState)
            encoder?.setFragmentTexture(texture, index: 0)
            
            var fragmentUniforms = FragmentUniforms(
                tileCount: tileCount,
                rotation: rotation * .pi / 180.0,
                offsetX: Float(offset.x),
                offsetY: Float(offset.y)
            )
            
            encoder?.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<FragmentUniforms>.size, index: 0)
            
            encoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder?.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

struct FragmentUniforms {
    var tileCount: Float
    var rotation: Float
    var offsetX: Float
    var offsetY: Float
}

// MARK: - Rotation Dial

struct RotationDial: View {
    @Binding var angle: Float
    
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let radians = Double(angle) * .pi / 180.0 - .pi / 2
            
            ZStack {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.4), lineWidth: 2)
                
                Circle()
                    .fill(Color.gray.opacity(0.08))
                
                // Tick marks at cardinal points
                ForEach(0..<12) { i in
                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 1, height: i % 3 == 0 ? 6 : 3)
                        .offset(y: -radius + 4)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
                
                // Indicator line
                Path { path in
                    path.move(to: CGPoint(x: radius, y: radius))
                    path.addLine(to: CGPoint(
                        x: radius + cos(radians) * (radius - 8),
                        y: radius + sin(radians) * (radius - 8)
                    ))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                
                // Center knob
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - radius
                        let dy = value.location.y - radius
                        var degrees = atan2(dy, dx) * 180.0 / .pi + 90.0
                        if degrees < 0 { degrees += 360 }
                        angle = Float(degrees.truncatingRemainder(dividingBy: 360))
                    }
            )
        }
    }
}
