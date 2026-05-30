import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import MetalKit

// Minimal SCNView subclass — forwards scroll-wheel events to our custom orbit camera.
class PreviewSCNView: SCNView {
    weak var coordinator: PreviewView3D.Coordinator?
    override func scrollWheel(with event: NSEvent) {
        coordinator?.handleScrollWheel(event)
    }
}

struct PreviewView3D: NSViewRepresentable {
    let generator: TextureGenerator
    let redrawTrigger: Int
    let applyTrigger: Int
    let sourceImageID: ObjectIdentifier?
    let refocusTrigger: Int
    let floorStyle: TextureGenerator.FloorStyle
    let cameraAzimuth: Float
    let cameraElevation: Float
    let floorColor: Color
    let domeColor: Color
    let iblPreset: TextureGenerator.IBLPreset
    let iblRotation: Float
    let lightingRig: TextureGenerator.LightingRig
    let lightIntensity: Float
    let bounceLightIntensity: Float
    let fillLightIntensity: Float
    let rimLightIntensity: Float
    let cameraFillEnabled: Bool
    let cameraFillIntensity: Float
    let ringLightEnabled: Bool
    let ringLightIntensity: Float
    let underLightEnabled: Bool
    let underLightIntensity: Float
    let showLightGizmos: Bool
    let ballTextureScale: Float
    let ballTextureOffsetX: Float
    let ballTextureOffsetY: Float
    let ballTextureRotation: Float
    let lightColor: Color
    let lightTemperature: Float
    let underLightSpread: Float
    let underLightColor: Color
    let cameraFillColor: Color
    let ringLightColor: Color

    func makeNSView(context: Context) -> PreviewSCNView {
        let view = PreviewSCNView(frame: .zero, options: [
            SCNView.Option.preferredDevice.rawValue: generator.device,
            SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)
        ])
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .white
        view.preferredFramesPerSecond = 60
        
        let scene = loadScene()
        scene.background.contents = NSColor.white
        
        // Cache extent BEFORE adding SCNFloor — floor pollutes rootNode.boundingBox
        let (preMinV, preMaxV) = scene.rootNode.boundingBox
        let preExtent = Float(max(abs(preMaxV.x - preMinV.x),
                                  max(abs(preMaxV.y - preMinV.y), abs(preMaxV.z - preMinV.z))))
        context.coordinator.sceneExtent  = preExtent > 0.0001 ? preExtent : 2.0
        context.coordinator.sceneCenterX = Float((preMinV.x + preMaxV.x) / 2)
        context.coordinator.sceneCenterY = Float((preMinV.y + preMaxV.y) / 2)
        context.coordinator.sceneCenterZ = Float((preMinV.z + preMaxV.z) / 2)
        context.coordinator.floorY       = Float(preMinV.y)

        configureLights(in: scene)
        updateEnvironment(in: scene)

        // Resolve the orbit target to the shader ball centre (before floor is added)
        let sceneCenter = SCNVector3(
            CGFloat(context.coordinator.sceneCenterX),
            CGFloat(context.coordinator.sceneCenterY),
            CGFloat(context.coordinator.sceneCenterZ))
        let ballCenter = findBallCenter(in: scene) ?? sceneCenter
        context.coordinator.defaultCameraTarget = ballCenter

        frameCamera(for: view, in: scene, target: ballCenter)

        // Initialise live orbit state from the slider defaults
        context.coordinator.orbitAzimuth   = cameraAzimuth
        context.coordinator.orbitElevation = cameraElevation
        context.coordinator.orbitDistance  = context.coordinator.sceneExtent * 2.2
        context.coordinator.lastRefocusTrigger  = refocusTrigger
        context.coordinator.lastCameraAzimuth   = cameraAzimuth
        context.coordinator.lastCameraElevation = cameraElevation

        // Custom orbit: click-drag to orbit, pinch / scroll-wheel to zoom
        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleOrbitPan(_:)))
        view.addGestureRecognizer(pan)

        let pinch = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleMagnify(_:)))
        view.addGestureRecognizer(pinch)

        view.coordinator = context.coordinator

        view.scene = scene
        context.coordinator.sceneView = view
        context.coordinator.scene     = scene
        context.coordinator.lastTrigger = -1
        context.coordinator.cacheNodes(in: scene)

        // Floor and bowl must be added AFTER frameCamera — SCNFloor has a non-finite
        // bounding box that would throw off the camera distance calculation.
        addStudioFloor(in: scene)
        updateSceneColors(in: scene)
        applyTextures(to: scene, coordinator: context.coordinator)
        updateLights(in: scene, coordinator: context.coordinator)
        updateUnderLight(in: scene, coordinator: context.coordinator)
        updateFollowLights(in: scene, coordinator: context.coordinator)
        updateAllGizmos(coordinator: context.coordinator)

        // SceneKit needs a poke after we change scene contents
        view.setNeedsDisplay(view.bounds)
        
        return view
    }
    
    func updateNSView(_ nsView: PreviewSCNView, context: Context) {
        guard let scene = nsView.scene else { return }
        if context.coordinator.lastRefocusTrigger != refocusTrigger {
            context.coordinator.lastRefocusTrigger = refocusTrigger
            doRefocus(view: nsView, coordinator: context.coordinator)
        }
        // applyTextures is expensive — skip when nothing texture-related changed
        let th = applyTrigger &* 31337 ^ redrawTrigger &* 999983
            ^ (sourceImageID.map { Int(bitPattern: $0) } ?? 0)
            ^ Int(ballTextureScale.bitPattern) ^ Int(ballTextureOffsetX.bitPattern) &* 1000003
            ^ Int(ballTextureOffsetY.bitPattern) &* 1000033 ^ Int(ballTextureRotation.bitPattern) &* 1000037
        if context.coordinator.lastTextureHash != th {
            context.coordinator.lastTextureHash = th
            applyTextures(to: scene, coordinator: context.coordinator)
        }
        updateLights(in: scene, coordinator: context.coordinator)
        updateUnderLight(in: scene, coordinator: context.coordinator)
        updateFollowLights(in: scene, coordinator: context.coordinator)
        updateAllGizmos(coordinator: context.coordinator)
        updateEnvironment(in: scene)
        updateStudioFloor(in: scene)
        updateSceneColors(in: scene)
        if context.coordinator.lastCameraAzimuth != cameraAzimuth ||
           context.coordinator.lastCameraElevation != cameraElevation {
            context.coordinator.lastCameraAzimuth   = cameraAzimuth
            context.coordinator.lastCameraElevation = cameraElevation
            updateCameraOrbit(view: nsView, coordinator: context.coordinator)
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var sceneView: SCNView?
        var lastTrigger: Int = -1
        var diffuseImage: NSImage?
        var normalImage: NSImage?
        var roughnessImage: NSImage?
        var metallicImage: NSImage?
        var aoImage: NSImage?
        // Cached before SCNFloor is added — floor pollutes rootNode.boundingBox
        var sceneExtent: Float = 2.0
        var sceneCenterX: Float = 0.0
        var sceneCenterY: Float = 0.0
        var sceneCenterZ: Float = 0.0
        var defaultCameraTarget: SCNVector3 = SCNVector3(0, 0, 0)
        var lastRefocusTrigger: Int = 0
        var floorY: Float = 0.0
        var lastCameraAzimuth: Float   = 45.0
        var lastCameraElevation: Float = 20.0
        // Live orbit state — single source of truth for all camera movement
        var orbitAzimuth: Float   = 45.0
        var orbitElevation: Float = 20.0
        var orbitDistance: Float  = 2.0

        weak var scene: SCNScene?
        var ringLightEnabled: Bool    = false
        var ringLightIntensity: Float = 800.0
        var ringLightRadius: Float    = 0.3
        var ringLightColor: NSColor   = .white

        // Node refs cached once in cacheNodes() — avoids childNode(withName:recursively:) on every update
        var keyLightNode: SCNNode?
        var fillLightNode: SCNNode?
        var rimLightNode: SCNNode?
        var sbKeyNode: SCNNode?
        var underLightNode: SCNNode?
        var cameraFillNode: SCNNode?
        var rowLightNodes: [SCNNode] = []
        var ringLightNodes: [SCNNode] = []
        var gizmoNodes: [SCNNode] = []
        var lastTextureHash: Int = -1

        func cacheNodes(in scene: SCNScene) {
            keyLightNode   = scene.rootNode.childNode(withName: "KeyLight",   recursively: false)
            fillLightNode  = scene.rootNode.childNode(withName: "FillLight",  recursively: false)
            rimLightNode   = scene.rootNode.childNode(withName: "RimLight",   recursively: false)
            sbKeyNode      = scene.rootNode.childNode(withName: "SoftboxKey", recursively: false)
            underLightNode = scene.rootNode.childNode(withName: "UnderLight", recursively: false)
            rowLightNodes  = (0..<5).compactMap { scene.rootNode.childNode(withName: "RowLight_\($0)",  recursively: false) }
            ringLightNodes = (0..<8).compactMap { scene.rootNode.childNode(withName: "RingLight_\($0)", recursively: false) }
            if let cam = scene.rootNode.childNode(withName: "DefaultCamera", recursively: false) {
                cameraFillNode = cam.childNode(withName: "CameraFill", recursively: false)
            }
            let parents: [SCNNode] = [keyLightNode, fillLightNode, rimLightNode, sbKeyNode, underLightNode]
                .compactMap { $0 } + rowLightNodes + ringLightNodes
            gizmoNodes = parents.compactMap { n in
                n.childNode(withName: (n.name ?? "") + "_Gizmo", recursively: false)
            }
        }

        // Positions the 8 ring lights in a circle in the camera's image plane.
        func updateRingLights() {
            guard !ringLightNodes.isEmpty else { return }
            let el = orbitElevation * .pi / 180
            let az = orbitAzimuth   * .pi / 180
            let d  = orbitDistance
            let r  = d * ringLightRadius
            let t  = defaultCameraTarget
            let rightX =  cos(az), rightY: Float = 0, rightZ = -sin(az)
            let upX    = -sin(az) * sin(el), upY = cos(el), upZ = -cos(az) * sin(el)
            let camX = Float(t.x) + cos(el) * sin(az) * d
            let camY = Float(t.y) + sin(el) * d
            let camZ = Float(t.z) + cos(el) * cos(az) * d
            for (i, n) in ringLightNodes.enumerated() {
                let theta = Float(i) * (.pi / 4)
                let lx = camX + r * (cos(theta) * rightX + sin(theta) * upX)
                let ly = camY + r * (cos(theta) * rightY + sin(theta) * upY)
                let lz = camZ + r * (cos(theta) * rightZ + sin(theta) * upZ)
                n.position = SCNVector3(CGFloat(lx), CGFloat(ly), CGFloat(lz))
                n.look(at: t)
                n.light?.intensity = ringLightEnabled ? CGFloat(ringLightIntensity) : 0
                n.light?.color     = ringLightColor
            }
        }

        // Computes camera position + orientation from (orbitAzimuth, orbitElevation, orbitDistance)
        // relative to defaultCameraTarget, with zero roll guaranteed.
        // Enforces the spherical cage: floor at −5°, ceiling at 85°, distance [0.5x … 4x extent].
        func applyOrbit() {
            guard let pov = sceneView?.pointOfView else { return }
            orbitElevation = max(-45.0,         min(85.0,               orbitElevation))
            orbitDistance  = max(sceneExtent * 0.5, min(sceneExtent * 4.0, orbitDistance))
            let el = CGFloat(orbitElevation) * .pi / 180
            let az = CGFloat(orbitAzimuth) * .pi / 180
            let d  = CGFloat(orbitDistance)
            let t  = defaultCameraTarget
            pov.position    = SCNVector3(t.x + cos(el) * sin(az) * d,
                                         t.y + sin(el) * d,
                                         t.z + cos(el) * cos(az) * d)
            pov.eulerAngles = SCNVector3(-el, az, 0)
            updateRingLights()
        }

        // Left-click drag (or trackpad click-drag) orbits around the shader ball.
        @objc func handleOrbitPan(_ rec: NSPanGestureRecognizer) {
            guard let view = sceneView, rec.state == .changed else { return }
            let delta = rec.translation(in: view)
            rec.setTranslation(.zero, in: view)
            orbitAzimuth   += Float(delta.x) * 0.5   // drag right → az increases
            orbitElevation -= Float(delta.y) * 0.5   // drag up   → el increases
            orbitElevation  = max(-89, min(89, orbitElevation))
            applyOrbit()
        }

        // Pinch to zoom (trackpad two-finger pinch).
        @objc func handleMagnify(_ rec: NSMagnificationGestureRecognizer) {
            guard rec.state == .changed else { return }
            // magnification > 0 = fingers apart = zoom in (move camera closer)
            let scale = Float(max(0.05, 1.0 - rec.magnification * 0.9))
            orbitDistance = max(sceneExtent * 0.2, orbitDistance * scale)
            applyOrbit()
            rec.magnification = 0
        }

        // Scroll events — trackpad/Magic Mouse (hasPreciseScrollingDeltas) → orbit,
        // physical mouse wheel → zoom.  This matches SCNCameraController.orbitTurntable.
        func handleScrollWheel(_ event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                orbitAzimuth   += Float(event.scrollingDeltaX) * 0.3
                orbitElevation -= Float(event.scrollingDeltaY) * 0.3
                orbitElevation  = max(-89, min(89, orbitElevation))
            } else {
                // Mouse wheel: positive deltaY = scroll down = zoom out
                let factor = Float(1.0 + event.scrollingDeltaY * 0.08)
                orbitDistance = max(sceneExtent * 0.2, min(sceneExtent * 12, orbitDistance * max(0.1, factor)))
            }
            applyOrbit()
        }
    }
    
    // MARK: - Scene Setup
    
    private func loadScene() -> SCNScene {
        guard let url = Bundle.main.url(forResource: "RS_ShaderBallScene_nobackdrop", withExtension: "usdz") else {
            NSLog("PreviewView3D: RS_ShaderBallScene_nobackdrop.usdz not found in bundle. Falling back to sphere.")
            return makeFallbackScene()
        }
        
        // MDLAsset eagerly flattens the USD hierarchy and resolves all references,
        // avoiding the SCNReferenceNode lazy-loading pitfall.
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        
        // The USDZ ships with zero UV channels on every mesh — confirmed in
        // Console diagnostics. ModelIO can auto-unwrap UVs so SceneKit has
        // something to sample our PBR textures against.
        ensureUVs(in: asset)
        
        let scene = SCNScene(mdlAsset: asset)
        
        // Defensive: force-load any remaining SCNReferenceNodes (multi-pass).
        for _ in 0..<3 {
            var loadedAny = false
            scene.rootNode.enumerateHierarchy { node, _ in
                if let ref = node as? SCNReferenceNode, !ref.isLoaded {
                    ref.load()
                    loadedAny = true
                }
            }
            if !loadedAny { break }
        }
        return scene
    }
    
    private func ensureUVs(in asset: MDLAsset) {
        let attrName = MDLVertexAttributeTextureCoordinate
        let objects = asset.childObjects(of: MDLMesh.self)
        var unwrappedCount = 0
        var alreadyHadCount = 0
        for case let mesh as MDLMesh in objects {
            if mesh.vertexDescriptor.attributeNamed(attrName) == nil {
                mesh.addUnwrappedTextureCoordinates(forAttributeNamed: attrName)
                unwrappedCount += 1
            } else {
                alreadyHadCount += 1
            }
        }
        NSLog("PreviewView3D: unwrapped UVs on \(unwrappedCount) mesh(es) (\(alreadyHadCount) already had UVs) out of \(objects.count) total.")
    }
    
    private func makeFallbackScene() -> SCNScene {
        let fallback = SCNScene()
        let sphere = SCNSphere(radius: 1.0)
        sphere.segmentCount = 96
        let node = SCNNode(geometry: sphere)
        fallback.rootNode.addChildNode(node)
        return fallback
    }
    
    /// Returns the world-space center of the first geometry node whose name contains
    /// "sphere" or "ball" — the main shader ball.  Returns nil when no such node exists.
    private func findBallCenter(in scene: SCNScene) -> SCNVector3? {
        var found: SCNNode? = nil
        scene.rootNode.enumerateHierarchy { node, stop in
            guard node.geometry != nil else { return }
            let lower = (node.name ?? "").lowercased()
            guard lower.contains("sphere") || lower.contains("ball") else { return }
            found = node
            stop.pointee = true
        }
        guard let node = found else { return nil }
        let (lo, hi) = node.boundingBox
        let local = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        return node.convertPosition(local, to: nil)
    }

    private func frameCamera(for view: SCNView, in scene: SCNScene, target: SCNVector3? = nil) {
        let (minV, maxV) = scene.rootNode.boundingBox
        let extent = Float(max(
            abs(maxV.x - minV.x),
            max(abs(maxV.y - minV.y), abs(maxV.z - minV.z))
        ))
        // Use provided ball center when available; fall back to bounding box centre
        let cx: Float
        let cy: Float
        let cz: Float
        if let t = target {
            cx = Float(t.x); cy = Float(t.y); cz = Float(t.z)
        } else {
            cx = Float((minV.x + maxV.x) / 2)
            cy = Float((minV.y + maxV.y) / 2)
            cz = Float((minV.z + maxV.z) / 2)
        }
        let safeExtent: Float = extent > 0.0001 ? extent : 2.0
        let distance: Float = safeExtent * 2.2
        
        let cameraNode = SCNNode()
        cameraNode.name = "DefaultCamera"
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = Double(safeExtent) * 0.01
        camera.zFar = Double(safeExtent) * 50.0
        camera.wantsHDR = false
        cameraNode.camera = camera
        let az = generator.cameraAzimuth * .pi / 180
        let el = generator.cameraElevation * .pi / 180
        cameraNode.position = SCNVector3(
            CGFloat(cx + cos(el) * sin(az) * distance),
            CGFloat(cy + sin(el) * distance),
            CGFloat(cz + cos(el) * cos(az) * distance))
        // Explicit euler angles guarantee zero roll — look(at:) can introduce roll
        // depending on the camera's prior orientation in the controller.
        cameraNode.eulerAngles = SCNVector3(-CGFloat(el), CGFloat(az), 0)

        // Camera Fill — directional child of camera node, always illuminates camera-facing side
        let cfNode = SCNNode()
        cfNode.name = "CameraFill"
        let cf = SCNLight()
        cf.type = .directional
        cf.intensity = generator.cameraFillEnabled ? CGFloat(generator.cameraFillIntensity) : 0
        cf.castsShadow = false
        cf.color = NSColor(generator.cameraFillColor)
        cfNode.light = cf
        cameraNode.addChildNode(cfNode)

        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
    }
    
    private func configureLights(in scene: SCNScene) {
        let (minV, maxV) = scene.rootNode.boundingBox
        let extent = Float(max(abs(maxV.x - minV.x), max(abs(maxV.y - minV.y), abs(maxV.z - minV.z))))
        let safeExtent: Float = extent > 0.0001 ? extent : 2.0
        let gizmoRadius = CGFloat(max(0.02, safeExtent * 0.04))

        // Adds a small unlit sphere child to a light node so its position is visible in the viewport.
        func addGizmo(to node: SCNNode) {
            let geo = SCNSphere(radius: gizmoRadius)
            geo.segmentCount = 6
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents  = NSColor.white
            mat.emission.contents = NSColor.white
            geo.firstMaterial = mat
            let g = SCNNode(geometry: geo)
            g.name = (node.name ?? "Light") + "_Gizmo"
            g.isHidden = true
            node.addChildNode(g)
        }

        let keyNode = SCNNode()
        keyNode.name = "KeyLight"
        let key = SCNLight()
        key.type = .directional
        key.intensity = CGFloat(generator.lightIntensity)
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 10
        key.shadowSampleCount = 32
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.automaticallyAdjustsShadowProjection = true
        key.maximumShadowDistance = CGFloat(safeExtent * 12.0)
        key.color = NSColor(generator.lightColor)
        key.temperature = CGFloat(generator.lightTemperature)
        keyNode.light = key
        scene.rootNode.addChildNode(keyNode)
        addGizmo(to: keyNode)

        // Low-level ambient — fill/rim directional lights do the heavy lifting
        let ambientNode = SCNNode()
        ambientNode.name = "AmbientFill"
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 60
        ambient.color = NSColor.white
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Fill light — directional, no shadow, positioned opposite key in updateLights
        let fillNode = SCNNode()
        fillNode.name = "FillLight"
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = CGFloat(generator.fillLightIntensity)
        fill.castsShadow = false
        fill.color = NSColor.white
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)
        addGizmo(to: fillNode)

        // Rim light — directional, no shadow, positioned behind-side in updateLights
        let rimNode = SCNNode()
        rimNode.name = "RimLight"
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = CGFloat(generator.rimLightIntensity)
        rim.castsShadow = false
        rim.color = NSColor.white
        rimNode.light = rim
        scene.rootNode.addChildNode(rimNode)
        addGizmo(to: rimNode)

        // Softbox area light — rectangle emitter, active only when rig = .softbox
        let sbKeyNode = SCNNode()
        sbKeyNode.name = "SoftboxKey"
        let sbKey = SCNLight()
        sbKey.type = .area
        sbKey.areaType = .rectangle
        sbKey.areaExtents = simd_float3(safeExtent * 1.8, safeExtent * 1.8, 0)
        sbKey.intensity = 0
        sbKey.castsShadow = true
        sbKey.shadowMode = .deferred
        sbKey.shadowRadius = 4
        sbKey.shadowSampleCount = 16
        sbKey.shadowMapSize = CGSize(width: 2048, height: 2048)
        sbKey.automaticallyAdjustsShadowProjection = true
        sbKey.maximumShadowDistance = CGFloat(safeExtent * 12.0)
        sbKey.color = NSColor.white
        sbKey.drawsArea = false
        sbKeyNode.light = sbKey
        scene.rootNode.addChildNode(sbKeyNode)
        addGizmo(to: sbKeyNode)

        // Under-light — spot from below pointing straight up, always added, toggled by generator.underLightEnabled
        let underNode = SCNNode()
        underNode.name = "UnderLight"
        let under = SCNLight()
        under.type = .spot
        under.intensity = 0
        under.castsShadow = false
        under.spotInnerAngle = 20
        under.spotOuterAngle = 40
        under.color = NSColor.white
        underNode.light = under
        scene.rootNode.addChildNode(underNode)
        addGizmo(to: underNode)

        // Row-rig lights — always added, intensity toggled per rig
        for i in 0..<5 {
            let n = SCNNode()
            n.name = "RowLight_\(i)"
            let l = SCNLight()
            l.type = .omni
            l.intensity = 0
            l.castsShadow = false
            l.color = NSColor(generator.lightColor)
            l.temperature = CGFloat(generator.lightTemperature)
            n.light = l
            scene.rootNode.addChildNode(n)
            addGizmo(to: n)
        }

        // Ring light — 8 spot nodes in camera plane; positions driven by coordinator.updateRingLights()
        for i in 0..<8 {
            let n = SCNNode()
            n.name = "RingLight_\(i)"
            let l = SCNLight()
            l.type = .spot
            l.intensity = 0
            l.castsShadow = false
            l.spotInnerAngle = 15
            l.spotOuterAngle = 40
            l.color = NSColor.white
            n.light = l
            scene.rootNode.addChildNode(n)
            addGizmo(to: n)
        }
    }

    private func updateLights(in scene: SCNScene, coordinator: Coordinator) {
        guard let keyNode = coordinator.keyLightNode else { return }
        let safeExtent = coordinator.sceneExtent
        let centerY    = coordinator.sceneCenterY
        let distance   = safeExtent * 2.0

        switch generator.lightingRig {

        case .studio:
            coordinator.sbKeyNode?.light?.intensity = 0
            let az: Float = generator.lightAzimuth * .pi / 180.0
            let el: Float = generator.lightElevation * .pi / 180.0
            keyNode.position = SCNVector3(CGFloat(distance * cos(el) * sin(az)),
                                          CGFloat(distance * sin(el) + centerY),
                                          CGFloat(distance * cos(el) * cos(az)))
            keyNode.look(at: SCNVector3(0, CGFloat(centerY), 0))
            keyNode.light?.intensity         = CGFloat(generator.lightIntensity)
            keyNode.light?.shadowRadius      = 10
            keyNode.light?.shadowSampleCount = 32
            keyNode.light?.color             = NSColor(generator.lightColor)
            keyNode.light?.temperature       = CGFloat(generator.lightTemperature)
            setRowLightsOff(coordinator: coordinator)
            updateFillRimLights(coordinator: coordinator,
                                keyAz: generator.lightAzimuth * .pi / 180,
                                keyEl: generator.lightElevation * .pi / 180)

        case .softbox:
            keyNode.light?.intensity = 0
            if let sbNode = coordinator.sbKeyNode {
                let az: Float = generator.lightAzimuth  * .pi / 180.0
                let el: Float = generator.lightElevation * .pi / 180.0
                sbNode.position = SCNVector3(CGFloat(distance * cos(el) * sin(az)),
                                             CGFloat(distance * sin(el) + centerY),
                                             CGFloat(distance * cos(el) * cos(az)))
                sbNode.look(at: SCNVector3(0, CGFloat(centerY), 0))
                sbNode.light?.intensity     = CGFloat(generator.lightIntensity)
                sbNode.light?.color         = NSColor(generator.lightColor)
                sbNode.light?.temperature   = CGFloat(generator.lightTemperature)
                sbNode.light?.areaExtents   = simd_float3(safeExtent * 1.8, safeExtent * 1.8, 0)
            }
            setRowLightsOff(coordinator: coordinator)
            updateFillRimLights(coordinator: coordinator,
                                keyAz: generator.lightAzimuth * .pi / 180,
                                keyEl: generator.lightElevation * .pi / 180)

        case .row:
            keyNode.light?.intensity = 0
            coordinator.sbKeyNode?.light?.intensity = 0
            disableFillRim(coordinator: coordinator)
            let perLight = CGFloat(generator.lightIntensity)
            let spread   = CGFloat(safeExtent) * 1.2
            let yPos     = CGFloat(centerY) + CGFloat(safeExtent) * 1.4
            let zPos     = CGFloat(safeExtent) * 0.6
            for (i, n) in coordinator.rowLightNodes.enumerated() {
                let t    = CGFloat(i) / 4.0
                n.position           = SCNVector3(spread * (t * 2.0 - 1.0) * 2.0, yPos, zPos)
                n.light?.intensity   = perLight
                n.light?.color       = NSColor(generator.lightColor)
                n.light?.temperature = CGFloat(generator.lightTemperature)
            }
        }
    }

    private func updateFillRimLights(coordinator: Coordinator, keyAz: Float, keyEl: Float) {
        let d       = coordinator.sceneExtent * 2.0
        let centerY = coordinator.sceneCenterY

        let fillAz = keyAz + .pi
        let fillEl = keyEl - 0.2
        if let n = coordinator.fillLightNode {
            n.position = SCNVector3(CGFloat(d * cos(fillEl) * sin(fillAz)),
                                    CGFloat(d * sin(fillEl) + centerY),
                                    CGFloat(d * cos(fillEl) * cos(fillAz)))
            n.look(at: SCNVector3(0, CGFloat(centerY), 0))
            n.light?.intensity   = CGFloat(generator.fillLightIntensity)
            n.light?.temperature = min(10000, CGFloat(generator.lightTemperature) + 1200)
        }

        let rimAz = keyAz + .pi * (5.0 / 6.0)
        let rimEl = keyEl + 0.2
        if let n = coordinator.rimLightNode {
            n.position = SCNVector3(CGFloat(d * cos(rimEl) * sin(rimAz)),
                                    CGFloat(d * sin(rimEl) + centerY),
                                    CGFloat(d * cos(rimEl) * cos(rimAz)))
            n.look(at: SCNVector3(0, CGFloat(centerY), 0))
            n.light?.intensity   = CGFloat(generator.rimLightIntensity)
            n.light?.temperature = max(2000, CGFloat(generator.lightTemperature) - 800)
        }
    }

    private func disableFillRim(coordinator: Coordinator) {
        coordinator.fillLightNode?.light?.intensity = 0
        coordinator.rimLightNode?.light?.intensity  = 0
    }

    private func setRowLightsOff(coordinator: Coordinator) {
        for n in coordinator.rowLightNodes { n.light?.intensity = 0 }
    }
    
    // MARK: - Procedural HDR Environment (IBL)

    private static var iblTextureCache = [TextureGenerator.IBLPreset: NSImage]()

    private func updateEnvironment(in scene: SCNScene) {
        let preset = generator.iblPreset
        if Self.iblTextureCache[preset] == nil {
            Self.iblTextureCache[preset] = Self.makeHDRIImage(preset: preset)
        }
        let img = Self.iblTextureCache[preset]
        // Drives PBR reflections + diffuse GI
        scene.lightingEnvironment.contents  = img
        scene.lightingEnvironment.intensity = CGFloat(generator.bounceLightIntensity)
        scene.lightingEnvironment.wrapS     = .repeat
        let rot = CGFloat(generator.iblRotation / 360.0)
        scene.lightingEnvironment.contentsTransform = SCNMatrix4MakeTranslation(rot, 0, 0)
        // Also render as the visible skybox so preset changes are immediately obvious
        scene.background.contents           = img
        scene.background.wrapS              = .repeat
        scene.background.contentsTransform  = SCNMatrix4MakeTranslation(rot, 0, 0)
    }

    // Generates a 512×256 equirectangular environment image for the given preset.
    // Sky gradient + virtual Gaussian light spots baked in.  Returns an NSImage
    // SceneKit can use directly for lightingEnvironment and scene.background.
    private static func makeHDRIImage(preset: TextureGenerator.IBLPreset) -> NSImage? {
        let W = 512, H = 256
        var px = [Float](repeating: 0, count: W * H * 4)

        struct SkyPalette { let sr, sg, sb, hr, hg, hb, gr, gg, gb: Float }
        struct Spot        { let azDeg, elDeg, r, g, b, sigmaDeg: Float }

        let pal: SkyPalette
        let spots: [Spot]

        switch preset {
        case .neutralStudio:
            pal   = SkyPalette(sr:0.55,sg:0.57,sb:0.60, hr:0.42,hg:0.43,hb:0.46, gr:0.10,gg:0.10,gb:0.11)
            spots = [Spot(azDeg:45,  elDeg:35, r:9.0, g:8.5, b:7.5, sigmaDeg:12),
                     Spot(azDeg:225, elDeg:15, r:1.8, g:1.9, b:2.2, sigmaDeg:30),
                     Spot(azDeg:195, elDeg:30, r:2.5, g:2.3, b:2.0, sigmaDeg:20)]
        case .productWhite:
            pal   = SkyPalette(sr:0.90,sg:0.90,sb:0.90, hr:0.82,hg:0.82,hb:0.82, gr:0.55,gg:0.55,gb:0.55)
            spots = [Spot(azDeg:0,   elDeg:30, r:3.0, g:3.0, b:3.0, sigmaDeg:35),
                     Spot(azDeg:90,  elDeg:30, r:3.0, g:3.0, b:3.0, sigmaDeg:35),
                     Spot(azDeg:180, elDeg:30, r:3.0, g:3.0, b:3.0, sigmaDeg:35),
                     Spot(azDeg:270, elDeg:30, r:3.0, g:3.0, b:3.0, sigmaDeg:35)]
        case .overcast:
            pal   = SkyPalette(sr:0.68,sg:0.70,sb:0.75, hr:0.58,hg:0.60,hb:0.63, gr:0.20,gg:0.20,gb:0.21)
            spots = []
        case .golden:
            pal   = SkyPalette(sr:0.18,sg:0.28,sb:0.70, hr:0.88,hg:0.52,hb:0.12, gr:0.10,gg:0.06,gb:0.02)
            spots = [Spot(azDeg:90,  elDeg:7,  r:14.0, g:8.0, b:1.5, sigmaDeg:5),
                     Spot(azDeg:270, elDeg:18, r:0.6,  g:0.8, b:2.0, sigmaDeg:55)]
        case .coolBlue:
            pal   = SkyPalette(sr:0.20,sg:0.32,sb:0.70, hr:0.28,hg:0.38,hb:0.65, gr:0.04,gg:0.05,gb:0.10)
            spots = [Spot(azDeg:30,  elDeg:40, r:6.5, g:7.5, b:10.0, sigmaDeg:10),
                     Spot(azDeg:210, elDeg:20, r:0.8, g:1.2, b:2.5,  sigmaDeg:40)]
        }

        // Precompute Cartesian spot directions + Gaussian denominator
        struct SpotVec { let x, y, z, r, g, b, inv2sig2: Float }
        let pi = Float.pi
        let svecs: [SpotVec] = spots.map { s in
            let az = s.azDeg * pi / 180;  let el = s.elDeg * pi / 180
            let sig = s.sigmaDeg * pi / 180;  let c = cos(el)
            return SpotVec(x: c*sin(az), y: sin(el), z: c*cos(az),
                           r: s.r, g: s.g, b: s.b, inv2sig2: 1.0 / (2*sig*sig))
        }

        for row in 0..<H {
            for col in 0..<W {
                let az = Float(col) / Float(W) * 2 * pi
                let el = (0.5 - Float(row) / Float(H)) * pi   // +π/2 top … −π/2 bottom

                // Sky/horizon/ground gradient by elevation
                let t = el / (pi * 0.5)                        // −1 … +1
                var r, g, b: Float
                if t >= 0 {
                    let s = pow(t, 0.75)
                    r = pal.hr + s*(pal.sr - pal.hr); g = pal.hg + s*(pal.sg - pal.hg)
                    b = pal.hb + s*(pal.sb - pal.hb)
                } else {
                    let s = pow(-t, 0.55)
                    r = pal.hr + s*(pal.gr - pal.hr); g = pal.hg + s*(pal.gg - pal.hg)
                    b = pal.hb + s*(pal.gb - pal.hb)
                }

                // Accumulate virtual light spots (Gaussian angular falloff)
                let ce = cos(el)
                let dx = ce*sin(az), dy = sin(el), dz = ce*cos(az)
                for sv in svecs {
                    let dot = max(-1, min(1, dx*sv.x + dy*sv.y + dz*sv.z))
                    let ang = acos(dot)
                    let f   = exp(-ang*ang * sv.inv2sig2)
                    r += sv.r*f; g += sv.g*f; b += sv.b*f
                }

                let i = (row * W + col) * 4
                px[i] = r;  px[i+1] = g;  px[i+2] = b;  px[i+3] = 1.0
            }
        }

        // Convert float data to 8-bit RGBA.
        // Use CGDataProvider(data:) so the CGImage owns a copy of the pixel data —
        // passing &bytes to CGContext is unsafe because Swift may relocate the array
        // after the call returns, leaving the context with a dangling pointer.
        var bytes = [UInt8](repeating: 255, count: W * H * 4)
        for i in 0..<(W * H) {
            bytes[i*4]   = UInt8(max(0, min(255, Int(px[i*4]   * 255))))
            bytes[i*4+1] = UInt8(max(0, min(255, Int(px[i*4+1] * 255))))
            bytes[i*4+2] = UInt8(max(0, min(255, Int(px[i*4+2] * 255))))
            bytes[i*4+3] = 255
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: W, height: H,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: W * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                               provider: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: W, height: H))
    }

    private func addStudioFloor(in scene: SCNScene) {
        guard scene.rootNode.childNode(withName: "StudioFloor", recursively: false) == nil else { return }
        let (minV, maxV) = scene.rootNode.boundingBox
        let extent = Float(max(abs(maxV.x - minV.x), max(abs(maxV.y - minV.y), abs(maxV.z - minV.z))))
        let safeExtent: Float = extent > 0.0001 ? extent : 2.0

        let floor = SCNFloor()
        floor.reflectivity = 0.12
        floor.reflectionFalloffStart = 0
        floor.reflectionFalloffEnd = CGFloat(safeExtent * 4.0)
        floor.reflectionResolutionScaleFactor = 0.5

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(white: 0.38, alpha: 1.0)
        mat.roughness.contents = NSNumber(value: 0.85)
        mat.metalness.contents = NSNumber(value: 0.0)
        floor.firstMaterial = mat

        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "StudioFloor"
        floorNode.castsShadow = false
        floorNode.position = SCNVector3(0, minV.y, 0)
        scene.rootNode.addChildNode(floorNode)
    }

    private func addStudioBowl(in scene: SCNScene, coordinator: Coordinator) {
        guard scene.rootNode.childNode(withName: "StudioBowl", recursively: false) == nil else { return }
        // Radius must exceed the max orbit distance (4× extent) so the backdrop
        // never clips out when the camera zooms to its far limit.
        let radius = CGFloat(coordinator.sceneExtent * 6.5)

        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 64

        let mat = SCNMaterial()
        mat.lightingModel = .constant  // unlit — its colour is the backdrop colour
        mat.diffuse.contents = NSColor(white: 0.86, alpha: 1.0)
        mat.isDoubleSided = false
        mat.cullMode = .front          // render inside surface only
        mat.writesToDepthBuffer = false
        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.name = "StudioBowl"
        node.castsShadow = false
        node.renderingOrder = -10      // draw behind everything
        // Sink the sphere slightly so the equator sits at floor level,
        // giving a smooth curved backdrop without a hard horizon edge.
        node.position = SCNVector3(0,
                                   CGFloat(coordinator.sceneCenterY - coordinator.sceneExtent * 0.4),
                                   0)
        scene.rootNode.addChildNode(node)
    }

    private func updateStudioFloor(in scene: SCNScene) {
        guard let floorNode = scene.rootNode.childNode(withName: "StudioFloor", recursively: false),
              let floor = floorNode.geometry as? SCNFloor else { return }
        switch generator.floorStyle {
        case .reflective:
            floor.reflectivity = 0.12
            floor.firstMaterial?.roughness.contents = NSNumber(value: 0.85)
        case .matte:
            floor.reflectivity = 0.0
            floor.firstMaterial?.roughness.contents = NSNumber(value: 1.0)
        }
    }

    private func updateSceneColors(in scene: SCNScene) {
        if let floorNode = scene.rootNode.childNode(withName: "StudioFloor", recursively: false),
           let mat = floorNode.geometry?.firstMaterial {
            mat.diffuse.contents = NSColor(generator.floorColor)
        }
        // Bowl removed — IBL image drives both scene.background and lightingEnvironment
    }

    private func updateAllGizmos(coordinator: Coordinator) {
        let visible = generator.showLightGizmos
        for node in coordinator.gizmoNodes {
            guard let parent = node.parent, let light = parent.light else {
                node.isHidden = true
                continue
            }
            let show = visible && light.intensity > 0
            node.isHidden = !show
            if show, let mat = node.geometry?.firstMaterial {
                let c = light.color as? NSColor ?? NSColor.white
                mat.diffuse.contents  = c
                mat.emission.contents = c
            }
        }
    }

    private func updateFollowLights(in scene: SCNScene, coordinator: Coordinator) {
        if let cf = coordinator.cameraFillNode {
            cf.light?.intensity = generator.cameraFillEnabled ? CGFloat(generator.cameraFillIntensity) : 0
            cf.light?.color     = NSColor(generator.cameraFillColor)
        }
        coordinator.ringLightEnabled   = generator.ringLightEnabled
        coordinator.ringLightIntensity = generator.ringLightIntensity
        coordinator.ringLightRadius    = generator.ringLightRadius
        coordinator.ringLightColor     = NSColor(generator.ringLightColor)
        coordinator.updateRingLights()
    }

    private func updateUnderLight(in scene: SCNScene, coordinator: Coordinator) {
        guard let n = coordinator.underLightNode else { return }
        let t = coordinator.defaultCameraTarget
        n.position    = SCNVector3(t.x, CGFloat(coordinator.floorY), t.z)
        // eulerAngles.x = π/2 points the node's -Z straight up, avoiding look(at:) gimbal lock
        n.eulerAngles = SCNVector3(CGFloat(Float.pi / 2), 0, 0)
        n.light?.intensity      = generator.underLightEnabled ? CGFloat(generator.underLightIntensity) : 0
        n.light?.spotOuterAngle = CGFloat(generator.underLightSpread)
        n.light?.spotInnerAngle = CGFloat(generator.underLightSpread) * 0.5
        n.light?.color          = NSColor(generator.underLightColor)
        n.light?.temperature    = CGFloat(generator.lightTemperature)
    }

    private func doRefocus(view: SCNView, coordinator: Coordinator) {
        coordinator.orbitAzimuth   = 45.0
        coordinator.orbitElevation = 20.0
        coordinator.orbitDistance  = coordinator.sceneExtent * 2.2
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.55
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coordinator.applyOrbit()
        SCNTransaction.commit()
    }

    private func updateCameraOrbit(view: SCNView, coordinator: Coordinator, duration: CGFloat = 0.3) {
        coordinator.orbitAzimuth   = generator.cameraAzimuth
        coordinator.orbitElevation = generator.cameraElevation
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coordinator.applyOrbit()
        SCNTransaction.commit()
    }

    // MARK: - Texture Application

    private func applyTextures(to scene: SCNScene, coordinator: Coordinator) {
        // For the diffuse we use the user's original NSImage directly — this
        // sidesteps the MTLTexture readback path which has been unreliable
        // for the SceneKit PBR pipeline on this hardware.
        coordinator.diffuseImage = generator.sourceImage
        
        // For the baked maps (normal/roughness/metallic/AO) we still need to
        // round-trip through the GPU output. Re-read only when a bake has
        // completed, gated on redrawTrigger.
        if coordinator.lastTrigger != redrawTrigger {
            coordinator.normalImage = nsImage(from: generator.normalTexture)
            coordinator.roughnessImage = nsImage(from: generator.roughnessTexture)
            coordinator.metallicImage = nsImage(from: generator.metallicTexture)
            coordinator.aoImage = nsImage(from: generator.aoTexture)
            coordinator.lastTrigger = redrawTrigger
        }
        
        let scale = generator.ballTextureScale > 0.0001 ? generator.ballTextureScale : 1.0
        let tx = generator.ballTextureOffsetX
        let ty = generator.ballTextureOffsetY
        let rot = generator.ballTextureRotation * .pi / 180.0
        
        var transform = SCNMatrix4Identity
        transform = SCNMatrix4Translate(transform, CGFloat(tx), CGFloat(ty), 0)
        transform = SCNMatrix4Rotate(transform, CGFloat(rot), 0, 0, 1)
        transform = SCNMatrix4Scale(transform, CGFloat(scale), CGFloat(scale), 1.0)
        
        // Diagnostic fallback colour confirms the override is working when no
        // texture is bound yet.
        let diffuse: Any = coordinator.diffuseImage ?? NSColor.systemPink
        let roughness: Any = coordinator.roughnessImage ?? NSNumber(value: 0.5)
        let metallic: Any = coordinator.metallicImage ?? NSNumber(value: 0.0)
        
        func configure(_ mat: SCNMaterial) {
            mat.lightingModel = .physicallyBased
            mat.isDoubleSided = false
            
            mat.diffuse.contents = diffuse
            mat.diffuse.wrapS = .repeat
            mat.diffuse.wrapT = .repeat
            mat.diffuse.contentsTransform = transform
            mat.diffuse.mappingChannel = 0
            
            if let normal = coordinator.normalImage {
                mat.normal.contents = normal
                mat.normal.wrapS = .repeat
                mat.normal.wrapT = .repeat
                mat.normal.contentsTransform = transform
                mat.normal.mappingChannel = 0
            }
            
            mat.roughness.contents = roughness
            mat.roughness.wrapS = .repeat
            mat.roughness.wrapT = .repeat
            mat.roughness.contentsTransform = transform
            mat.roughness.mappingChannel = 0
            
            mat.metalness.contents = metallic
            mat.metalness.wrapS = .repeat
            mat.metalness.wrapT = .repeat
            mat.metalness.contentsTransform = transform
            mat.metalness.mappingChannel = 0
            
            if let ao = coordinator.aoImage {
                mat.ambientOcclusion.contents = ao
                mat.ambientOcclusion.wrapS = .repeat
                mat.ambientOcclusion.wrapT = .repeat
                mat.ambientOcclusion.contentsTransform = transform
                mat.ambientOcclusion.mappingChannel = 0
            }
        }
        
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            guard node.name != "StudioFloor", node.name != "StudioBowl" else { return }
            guard node.name?.hasSuffix("_Gizmo") != true else { return }
            let elementCount = max(geometry.elements.count, 1)
            geometry.materials = (0..<elementCount).map { _ in
                let m = SCNMaterial()
                configure(m)
                return m
            }
        }
    }
    
    private func nsImage(from texture: MTLTexture?) -> NSImage? {
        guard let texture else { return nil }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        
        // Force opaque: if the texture's alpha channel was written as 0 anywhere
        // (compute kernels not setting alpha, or texture cleared to zero), the
        // resulting NSImage would render fully transparent and the ball appears
        // unshaded. Stamp every alpha byte to 255 and tell CGContext to ignore
        // the alpha channel entirely.
        var i = 3
        while i < bytes.count {
            bytes[i] = 255
            i += 4
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
