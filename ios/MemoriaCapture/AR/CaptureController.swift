import ARKit
import AudioToolbox
import CaptureCore
import SceneKit
import UIKit

/// 撮影画面の AR と撮影の制御（基準の設定・撮影前の判定・captureHighResolutionFrame・保存）。
@MainActor
final class CaptureController: ObservableObject {
    enum Phase: Equatable {
        case starting
        case unsupported(String)
        /// 作品の底の中心を探している（照準を平面に当てる）。
        case placingBase
        /// 円柱の高さ・半径を合わせている。
        case adjustingSize
        /// 基準があり、撮影できる。
        case capturing
        case failed(String)
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var hasPlaneHit = false
    @Published var heightCm: Double = 15 { didSet { updateObjectPreview() } }
    @Published var radiusCm: Double = 8 { didSet { updateObjectPreview() } }
    @Published private(set) var assessment = QualityAssessment.initial
    @Published private(set) var direction: DirectionContext?
    @Published private(set) var covered: Set<String> = []
    @Published private(set) var plan: DirectionPlan
    @Published private(set) var captureInFlight = false
    @Published private(set) var photoCount = 0
    @Published private(set) var referenceState: ReferenceState = .none
    @Published var banner: Banner?
    @Published var showWarningsSheet = false
    @Published var autoCaptureEnabled: Bool

    static let heightRangeCm: ClosedRange<Double> = 3...60
    static let radiusRangeCm: ClosedRange<Double> = 2...40

    let arView: ARSCNView
    let sessionId: String
    private let store: SessionStore
    private let thresholds: QualityThresholds
    private let masks: MaskProcessor
    private let onSessionChanged: @MainActor () -> Void
    private let processor: ARFrameProcessor
    private let overlay = SceneOverlay()
    private let focus = FocusController()
    private var evaluator: QualityEvaluator
    private let preferredTargetId: String?

    private var activeReferenceId: String?
    private var basePoint: SIMD3<Double>?
    private var objectToWorld: simd_double4x4?
    private var baseAnchor: ARAnchor?
    private var lastHit: SIMD3<Double>?
    private var reticleTimer: Timer?
    private var lastSampleTimestamp: Double = 0
    private var isRunning = false
    private var wasBackgrounded = false
    private var bannerTask: Task<Void, Never>?
    private var lastMarkerKey = ""
    private let saveQueue = DispatchQueue(label: "memoria.capture.save", qos: .userInitiated)

    init(sessionId: String, preferredTargetId: String?, store: SessionStore, settings: AppSettings, masks: MaskProcessor, onSessionChanged: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.preferredTargetId = preferredTargetId
        self.store = store
        thresholds = settings.thresholds
        self.masks = masks
        self.onSessionChanged = onSessionChanged
        autoCaptureEnabled = settings.autoCaptureEnabled
        evaluator = QualityEvaluator(thresholds: settings.thresholds)
        let session = try? store.loadSession(sessionId)
        let initialPlan = session?.directionPlan ?? DirectionPlanPreset.default.plan
        plan = initialPlan
        photoCount = session?.photos.count ?? 0
        if let object = session?.object {
            heightCm = min(Self.heightRangeCm.upperBound, max(Self.heightRangeCm.lowerBound, object.heightM * 100))
            radiusCm = min(Self.radiusRangeCm.upperBound, max(Self.radiusRangeCm.lowerBound, object.radiusM * 100))
        }
        processor = ARFrameProcessor(thresholds: settings.thresholds, plan: initialPlan)

        arView = ARSCNView(frame: .zero)
        arView.scene = SCNScene()
        arView.automaticallyUpdatesLighting = false
        arView.autoenablesDefaultLighting = false
        arView.session.delegateQueue = processor.delegateQueue
        arView.session.delegate = processor
        overlay.attach(to: arView)

        processor.onAnalysis = { [weak self] in self?.handle($0) }
        processor.onReferenceLost = { [weak self] reason in
            let message = reason == .anchorDrift
                ? "作品の位置がずれました。基準を設定し直してください"
                : "位置を見失いました。基準を設定し直してください"
            self?.invalidateReference(reason, message: message)
        }
        processor.onInterrupted = { [weak self] in
            self?.invalidateReference(.sessionInterrupted, message: "中断されました。基準を設定し直してください")
        }
        processor.onInterruptionEnded = { [weak self] in
            guard let self, self.isRunning else { return }
            self.runSession()
            self.beginPlacingBase()
        }
        processor.onFailed = { [weak self] error in
            guard let self else { return }
            self.invalidateReference(.sessionInterrupted, message: nil)
            self.stopReticle()
            self.phase = .failed("AR を開始できませんでした（\(error.localizedDescription)）")
        }
    }

    // MARK: 開始・停止

    func start() {
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .unsupported("この端末（またはシミュレーター）は AR のワールドトラッキングに対応していません。")
            return
        }
        isRunning = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // 前の AR セッションの基準は、世界座標が違うので使えない。
        invalidateStaleReferences()
        runSession()
        beginPlacingBase()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopReticle()
        invalidateReference(.sessionInterrupted, message: nil)
        arView.session.pause()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// アプリが裏へ回った。
    func didEnterBackground() {
        guard isRunning else { return }
        wasBackgrounded = true
        stopReticle()
        arView.session.pause()
    }

    /// アプリが前に戻った：中断と同じに扱い、基準を設定し直す。
    func didBecomeActive() {
        guard isRunning, wasBackgrounded else { return }
        wasBackgrounded = false
        invalidateReference(.sessionInterrupted, message: activeReferenceId == nil ? nil : "中断されました。基準を設定し直してください")
        runSession()
        beginPlacingBase()
    }

    func retryAfterFailure() {
        guard isRunning else {
            start()
            return
        }
        runSession()
        beginPlacingBase()
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.isLightEstimationEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }
        baseAnchor = nil
        processor.resetMotion()
        focus.reset()
        evaluator.reset()
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func invalidateStaleReferences() {
        _ = try? store.updateSession(sessionId) { s in
            let now = Date()
            for i in s.referenceFrames.indices where s.referenceFrames[i].isValid {
                s.referenceFrames[i].invalidatedAt = now
                s.referenceFrames[i].invalidationReason = .sessionInterrupted
            }
        }
        onSessionChanged()
    }

    // MARK: 基準

    func beginPlacingBase() {
        guard isRunning else { return }
        phase = .placingBase
        basePoint = nil
        hasPlaneHit = false
        overlay.hideObject()
        stopReticle()
        reticleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReticle() }
        }
    }

    private func stopReticle() {
        reticleTimer?.invalidate()
        reticleTimer = nil
        overlay.showReticle(at: nil)
    }

    private func updateReticle() {
        guard phase == .placingBase, arView.bounds.width > 0 else { return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let query = arView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal),
           let result = arView.session.raycast(query).first {
            let p = result.worldTransform.columns.3
            lastHit = SIMD3(Double(cleaning: p.x), Double(cleaning: p.y), Double(cleaning: p.z))
            overlay.showReticle(at: result.worldTransform)
            hasPlaneHit = true
        } else {
            lastHit = nil
            overlay.showReticle(at: nil)
            hasPlaneHit = false
        }
    }

    /// 「ここが底の中心」
    func confirmBasePoint() {
        guard phase == .placingBase, let hit = lastHit else { return }
        stopReticle()
        basePoint = hit
        phase = .adjustingSize
        updateObjectPreview()
    }

    private func updateObjectPreview() {
        guard phase == .adjustingSize || phase == .capturing else { return }
        overlay.showObject(base: basePoint, radiusM: radiusCm / 100, heightM: heightCm / 100)
    }

    /// 「基準を確定」：基準を記録し、基準点にアンカーを置く。正面は次の確定した写真で決まる。
    func confirmReference() {
        guard phase == .adjustingSize, let base = basePoint else { return }
        let heightM = (heightCm * 10).rounded() / 1000, radiusM = (radiusCm * 10).rounded() / 1000
        let session: CaptureSession
        do {
            session = try store.updateSession(sessionId) { s in
                let now = Date()
                for i in s.referenceFrames.indices where s.referenceFrames[i].isValid {
                    s.referenceFrames[i].invalidatedAt = now
                    s.referenceFrames[i].invalidationReason = .userReset
                }
                s.referenceFrames.append(ReferenceFrame(id: s.nextReferenceFrameId, createdAt: now, basePointWorld: base))
                s.object = ObjectSize(heightM: heightM, radiusM: radiusM)
            }
        } catch {
            showBanner("基準を保存できませんでした（\(error.localizedDescription)）", isError: true)
            return
        }
        activeReferenceId = session.referenceFrames.last?.id
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(Float(base.x), Float(base.y), Float(base.z), 1)
        let anchor = ARAnchor(name: "memoria-base", transform: transform)
        arView.session.add(anchor: anchor)
        baseAnchor = anchor
        objectToWorld = nil
        referenceState = .awaitingFront
        phase = .capturing
        evaluator.reset()
        onSessionChanged()
        refreshFromStore()
        updateObjectPreview()
    }

    /// 「基準をやり直す」（作品を動かしたときも）。
    func resetReference() {
        invalidateReference(.userReset, message: nil)
        beginPlacingBase()
    }

    /// 今の基準を無効にする。写真は残るが、撮影済みの方向は数えなくなる。
    private func invalidateReference(_ reason: InvalidationReason, message: String?) {
        if let id = activeReferenceId {
            _ = try? store.updateSession(sessionId) { s in
                if let i = s.referenceFrames.firstIndex(where: { $0.id == id }), s.referenceFrames[i].isValid {
                    s.referenceFrames[i].invalidatedAt = Date()
                    s.referenceFrames[i].invalidationReason = reason
                }
            }
            onSessionChanged()
        }
        let hadReference = activeReferenceId != nil
        activeReferenceId = nil
        objectToWorld = nil
        referenceState = .none
        covered = []
        direction = nil
        if let anchor = baseAnchor { arView.session.remove(anchor: anchor) }
        baseAnchor = nil
        overlay.hideObject()
        pushReference()
        if let message, hadReference || reason == .sessionInterrupted { showBanner(message, isError: true) }
        if isRunning, phase == .capturing || phase == .adjustingSize {
            beginPlacingBase()
        }
    }

    /// 保存した中身から、撮影済みの方向・正面・枚数を読み直す。
    private func refreshFromStore() {
        guard let session = try? store.loadSession(sessionId) else { return }
        photoCount = session.photos.count
        plan = session.directionPlan
        if let id = activeReferenceId, let reference = session.referenceFrame(id: id), reference.isValid {
            objectToWorld = reference.objectToWorld?.simd
            referenceState = objectToWorld == nil ? .awaitingFront : .ready
            covered = Coverage.coveredTargetIds(photos: session.photos, referenceFrameId: id)
        } else {
            covered = []
        }
        pushReference()
        updateMarkers(nextId: direction?.nextTarget?.id, force: true)
    }

    private func pushReference() {
        var reference = LiveReference(plan: plan)
        reference.state = referenceState
        reference.basePoint = activeReferenceId == nil ? nil : basePoint
        reference.heightM = heightCm / 100
        reference.radiusM = radiusCm / 100
        reference.objectToWorld = objectToWorld
        reference.anchorId = baseAnchor?.identifier
        reference.covered = covered
        reference.preferredTargetId = preferredTargetId
        processor.reference = reference
    }

    private func updateMarkers(nextId: String?, force: Bool = false) {
        let key = "\(objectToWorld != nil)|\(covered.sorted())|\(nextId ?? "")"
        guard force || key != lastMarkerKey else { return }
        lastMarkerKey = key
        overlay.showMarkers(plan: plan, objectToWorld: objectToWorld, heightM: heightCm / 100, radiusM: radiusCm / 100, covered: covered, nextId: nextId)
    }

    // MARK: 撮影前の判定

    private func handle(_ analysis: LiveAnalysis) {
        guard isRunning else { return }
        var sample = analysis.sample
        sample.captureInFlight = captureInFlight
        // 設定中・基準なしのときは、収まりと方向は分からない扱い。
        if phase != .capturing {
            sample.reference = .none
            sample.projection = nil
            sample.direction = nil
        }
        lastSampleTimestamp = sample.timestamp
        assessment = evaluator.evaluate(sample)
        direction = sample.direction
        if phase == .capturing {
            updateMarkers(nextId: sample.direction?.nextTarget?.id)
        }
        if let center = analysis.normalizedCenter, phase == .capturing {
            focus.focus(at: center)
        }
        if phase == .capturing, autoCaptureEnabled, assessment.canAutoCapture, !showWarningsSheet {
            capture(trigger: .auto, warningsAcknowledged: false)
        }
    }

    // MARK: 撮影

    /// シャッター（手動）。警告があれば先に確認を出す。
    func shutterTapped() {
        guard !captureInFlight, assessment.canManualCapture else { return }
        if assessment.hasWarnings {
            showWarningsSheet = true
        } else {
            capture(trigger: .manual, warningsAcknowledged: false)
        }
    }

    /// 警告を確認して「このまま撮る」。
    func captureAcknowledgingWarnings() {
        showWarningsSheet = false
        capture(trigger: .manual, warningsAcknowledged: true)
    }

    private func capture(trigger: CaptureTrigger, warningsAcknowledged: Bool) {
        // 撮影は 1 枚ずつ。撮っている間の要求は無視する。
        guard isRunning, !captureInFlight else { return }
        guard assessment.canManualCapture || trigger == .auto else { return }
        captureInFlight = true
        let context = CaptureContext(
            trigger: trigger,
            referenceFrameId: phase == .capturing ? activeReferenceId : nil,
            liveQuality: assessment.liveRecord(warningsAcknowledged: warningsAcknowledged),
            deviceOrientation: DeviceInfoProvider.name(of: UIDevice.current.orientation),
            displayRotationDegClockwise: 0,
            capturedAt: Date()
        )
        arView.session.captureHighResolutionFrame { [weak self] frame, error in
            // 返ってきたフレームから、写真と姿勢・K・時刻・露出をまとめて取る（currentFrame は使わない）。
            guard let frame else {
                let message = error?.localizedDescription ?? "不明なエラー"
                onMain { self?.finishCapture(.failure(CaptureError.captureFailed(message))) }
                return
            }
            let pixelBuffer = frame.capturedImage
            let camera = frame.camera
            let (state, reason) = camera.trackingState.core
            let info = CapturedFrameInfo(
                cameraToWorld: simd_double4x4(cleaning: camera.transform),
                intrinsics: simd_double3x3(cleaning: camera.intrinsics),
                intrinsicsResolution: PixelSize(width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height)),
                imageSize: PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                timestamp: frame.timestamp,
                exposureDuration: camera.exposureDuration > 0 ? camera.exposureDuration : nil,
                exposureOffset: camera.exposureOffset.isFinite ? Double(cleaning: camera.exposureOffset) : nil,
                trackingState: state, trackingReason: reason
            )
            var finalContext = context
            finalContext.displayRotationDegClockwise = DisplayRotation.rotation(deviceOrientation: context.deviceOrientation)
                ?? DisplayRotation.rotationFromGravity(upInCameraX: Double(camera.transform.columns.0.y), upInCameraY: Double(camera.transform.columns.1.y))
            self?.save(image: CapturedImage(pixelBuffer: pixelBuffer), info: info, context: finalContext)
        }
    }

    nonisolated private func save(image: CapturedImage, info: CapturedFrameInfo, context: CaptureContext) {
        let store = self.store, sessionId = self.sessionId
        saveQueue.async { [weak self] in
            let result: Result<Photo, Error> = autoreleasepool {
                if !info.intrinsicsMatchImage {
                    // 黙って K を直さない：画像の大きさと K の画像の大きさを両方記録する。
                    print("[Capture] imageResolution \(info.intrinsicsResolution) と画像 \(info.imageSize) が違います")
                }
                guard let jpeg = JPEGEncoder.shared.jpeg(from: image.pixelBuffer) else {
                    return .failure(CaptureError.encodeFailed)
                }
                let photoId = SessionStore.newId()
                return Result {
                    try store.addPhoto(sessionId: sessionId, photoId: photoId, jpegData: jpeg) { session, sequence in
                        PhotoRecorder.makePhoto(in: &session, photoId: photoId, sequence: sequence, frame: info, context: context)
                    }
                }
            }
            onMain { self?.finishCapture(result) }
        }
    }

    private func finishCapture(_ result: Result<Photo, Error>) {
        captureInFlight = false
        evaluator.noteCapture(at: lastSampleTimestamp)
        switch result {
        case .success(let photo):
            AudioServicesPlaySystemSound(1108)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refreshFromStore()
            masks.enqueue(sessionId: sessionId, photoId: photo.photoId)
            onSessionChanged()
            if !photo.direction.confirmed {
                showBanner("保存しました（方向は参考値です）", isError: false)
            }
        case .failure(let error):
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            switch error as? CaptureError {
            case .captureFailed?:
                showBanner("撮影できませんでした。もう一度撮影してください", isError: true)
            default:
                showBanner("保存できませんでした。もう一度撮影してください", isError: true)
            }
            print("[Capture] 失敗: \(error)")
        }
    }

    // MARK: 表示

    func showBanner(_ message: String, isError: Bool) {
        banner = Banner(message: message, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// 案内の 1 行目。
    var guidanceText: String {
        switch phase {
        case .starting: return "カメラを準備しています"
        case .unsupported(let message), .failed(let message): return message
        case .placingBase:
            return hasPlaneHit ? "黄色い印を作品の底の中心に合わせて「ここが底の中心」を押してください"
                : "作品を置いた机をゆっくり映してください（平面を探しています）"
        case .adjustingSize: return "円柱が作品をちょうど囲むように、高さと半径を合わせてください"
        case .capturing: return assessment.primaryMessage
        }
    }
}

/// 保存のキューへ渡すピクセルバッファ（JPEG にするまでの間だけ持つ。ARFrame は持たない）。
struct CapturedImage: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

enum CaptureError: Error {
    case captureFailed(String)
    case encodeFailed
}
