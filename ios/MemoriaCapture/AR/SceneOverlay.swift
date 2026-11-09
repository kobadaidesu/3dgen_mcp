import ARKit
import CaptureCore
import SceneKit
import UIKit

/// AR の画面に重ねる 3D の印（基準の輪・作品を囲む円柱・撮る方向の印）。
/// ARSCNView の描画にだけ出る。captureHighResolutionFrame の写真（カメラの生の画像）には入らない。
@MainActor
final class SceneOverlay {
    let root = SCNNode()
    private let reticle = SCNNode()
    private let objectNode = SCNNode()
    private let baseRing = SCNNode()
    private let cylinder = SCNNode()
    private let markers = SCNNode()
    private var markerNodes: [String: SCNNode] = [:]

    static let coveredColor = UIColor.systemGreen
    static let checkingColor = UIColor.systemYellow
    static let retakeColor = UIColor.systemOrange
    static let nextColor = UIColor.systemCyan
    static let pendingColor = UIColor.white

    init() {
        let reticleRing = SCNNode(geometry: SCNTube(innerRadius: 0.035, outerRadius: 0.042, height: 0.001))
        reticleRing.geometry?.firstMaterial = Self.material(.systemYellow)
        let dot = SCNNode(geometry: SCNCylinder(radius: 0.004, height: 0.001))
        dot.geometry?.firstMaterial = Self.material(.systemYellow)
        reticle.addChildNode(reticleRing)
        reticle.addChildNode(dot)
        reticle.isHidden = true

        baseRing.geometry = SCNTube(innerRadius: 0.077, outerRadius: 0.083, height: 0.002)
        baseRing.geometry?.firstMaterial = Self.material(.systemOrange)
        cylinder.geometry = SCNCylinder(radius: 0.08, height: 0.15)
        cylinder.geometry?.firstMaterial = Self.material(UIColor.systemOrange.withAlphaComponent(0.22), writesDepth: false)
        objectNode.addChildNode(baseRing)
        objectNode.addChildNode(cylinder)
        objectNode.isHidden = true
        markers.isHidden = true

        root.addChildNode(reticle)
        root.addChildNode(objectNode)
        root.addChildNode(markers)
    }

    func attach(to view: ARSCNView) {
        view.scene.rootNode.addChildNode(root)
    }

    private static func material(_ color: UIColor, writesDepth: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = writesDepth
        m.blendMode = .alpha
        return m
    }

    /// 平面に当たった位置に照準を出す（nil なら隠す）。
    func showReticle(at transform: simd_float4x4?) {
        guard let transform else {
            reticle.isHidden = true
            return
        }
        reticle.simdTransform = transform
        reticle.isHidden = false
    }

    /// 基準点に輪と円柱を出す（nil なら隠す）。
    func showObject(base: SIMD3<Double>?, radiusM: Double, heightM: Double) {
        guard let base else {
            objectNode.isHidden = true
            return
        }
        objectNode.simdPosition = SIMD3(Float(base.x), Float(base.y), Float(base.z))
        if let tube = baseRing.geometry as? SCNTube {
            tube.innerRadius = CGFloat(max(0.005, radiusM - 0.003))
            tube.outerRadius = CGFloat(radiusM + 0.003)
        }
        if let cyl = cylinder.geometry as? SCNCylinder {
            cyl.radius = CGFloat(radiusM)
            cyl.height = CGFloat(heightM)
        }
        cylinder.simdPosition = SIMD3(0, Float(heightM / 2), 0)
        objectNode.isHidden = false
    }

    /// 撮る方向の印。正面が決まるまでは出さない。
    /// 色：そろった＝緑、確認中＝黄、撮り直し＝オレンジ、次に撮る方向＝水色（大きく）、未撮影＝白。
    func showMarkers(plan: DirectionPlan, objectToWorld: simd_double4x4?, heightM: Double, radiusM: Double, states: [String: TargetState], nextId: String?) {
        guard let objectToWorld else {
            markers.isHidden = true
            return
        }
        let wanted = Set(plan.targets.map(\.id))
        for (id, node) in markerNodes where !wanted.contains(id) {
            node.removeFromParentNode()
            markerNodes[id] = nil
        }
        let center = SIMD3(0, heightM / 2, 0)
        let distance = radiusM + 0.1
        for target in plan.targets {
            let node = markerNodes[target.id] ?? {
                let n = SCNNode(geometry: SCNSphere(radius: 0.012))
                n.geometry?.firstMaterial = Self.material(Self.pendingColor)
                markers.addChildNode(n)
                markerNodes[target.id] = n
                return n
            }()
            let az = Geometry.radians(target.azimuthDeg), el = Geometry.radians(target.elevationDeg)
            let local = center + distance * SIMD3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
            let world = objectToWorld * SIMD4(local, 1)
            node.simdPosition = SIMD3(Float(world.x), Float(world.y), Float(world.z))
            let color: UIColor
            switch states[target.id] ?? .notShot {
            case .done: color = Self.coveredColor
            case .checking: color = Self.checkingColor
            case .retake: color = Self.retakeColor
            case .notShot: color = target.id == nextId ? Self.nextColor : Self.pendingColor
            }
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.scale = target.id == nextId ? SCNVector3(1.5, 1.5, 1.5) : SCNVector3(1, 1, 1)
        }
        markers.isHidden = false
    }

    func hideObject() {
        objectNode.isHidden = true
        markers.isHidden = true
    }
}
