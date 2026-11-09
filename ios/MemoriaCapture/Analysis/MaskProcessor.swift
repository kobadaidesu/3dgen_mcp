import CaptureCore
import Foundation

/// 保存した写真の解析（明るさ・ブレ）とマスク作りを、1 枚ずつ順番に行う（メモリを抑えるため）。
final class MaskProcessor: @unchecked Sendable {
    private let store: SessionStore
    private let evaluator: QualityEvaluator
    private let queue = DispatchQueue(label: "memoria.masks", qos: .utility)
    private let lock = NSLock()
    private var pending: Set<String> = []

    /// 変わったセッション（メインスレッドで呼ぶ）。
    var onChange: (@MainActor (String) -> Void)?

    init(store: SessionStore, thresholds: QualityThresholds) {
        self.store = store
        evaluator = QualityEvaluator(thresholds: thresholds)
    }

    func pendingPhotoIds() -> Set<String> {
        lock.withLock { pending }
    }

    func hasPending(sessionId: String) -> Bool {
        let ids = pendingPhotoIds()
        guard !ids.isEmpty, let session = try? store.loadSession(sessionId) else { return false }
        return session.photos.contains { ids.contains($0.photoId) || $0.mask.status == .processing }
    }

    /// 写真の解析とマスク作りを順番待ちに入れる。
    func enqueue(sessionId: String, photoId: String) {
        let inserted = lock.withLock { pending.insert(photoId).inserted }
        guard inserted else { return }
        queue.async { [weak self] in
            self?.process(sessionId: sessionId, photoId: photoId)
        }
    }

    private func notify(_ sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?(sessionId) }
        }
    }

    private func process(sessionId: String, photoId: String) {
        defer {
            lock.withLock { _ = pending.remove(photoId) }
            notify(sessionId)
        }
        // 送信中なら少し待ってからやり直す（送信中のセッションは変えない）。
        if store.isBusy(sessionId) {
            lock.withLock { _ = pending.remove(photoId) }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.enqueue(sessionId: sessionId, photoId: photoId) }
            return
        }
        guard let session = try? store.loadSession(sessionId), let photo = session.photo(id: photoId) else { return }
        let imageURL = store.photoURL(sessionId, photoId: photoId)
        let region = SavedPhotoAnalyzer.objectRegion(photo: photo, session: session)

        autoreleasepool {
            // 1. 保存した写真の明るさ・シャープさ。
            if photo.quality.saved == nil,
               let metrics = SavedPhotoAnalyzer.metrics(jpegURL: imageURL, imageSize: PixelSize(width: photo.image.width, height: photo.image.height), roi: region) {
                let saved = evaluator.savedQuality(meanLuma: round(metrics.meanLuma, 4), sharpness: round(metrics.laplacianVariance, 6))
                _ = try? store.updateSession(sessionId) { s in
                    if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[i].quality.saved = saved }
                }
            }
            // 2. マスク（未生成のときだけ。ユーザーが選んだもの・確定したものは作り直さない）。
            guard photo.mask.status == .notGenerated || photo.mask.status == .processing else { return }
            setMask(sessionId: sessionId, photoId: photoId, MaskInfo(status: .processing, method: MaskInfo.visionMethod))
            notify(sessionId)
            do {
                let analysis = try MaskGenerator.analyze(imageURL: imageURL)
                guard let map = analysis.labelMap, analysis.instanceCount > 0 else {
                    setMask(sessionId: sessionId, photoId: photoId, MaskInfo(status: .noObject, method: MaskInfo.visionMethod, instanceCount: 0, selection: .auto))
                    return
                }
                // 作品の範囲を、ラベル画像の大きさに合わせる。
                let roi = region.map { $0.scaled(x: Double(map.width) / Double(photo.image.width), y: Double(map.height) / Double(photo.image.height)) }
                let selected = MaskInstanceSelector.autoSelect(map: map, roi: roi)
                try saveSelection(sessionId: sessionId, photo: photo, analysis: analysis, selected: selected, selection: .auto)
            } catch {
                setMask(sessionId: sessionId, photoId: photoId, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    private func setMask(sessionId: String, photoId: String, _ mask: MaskInfo) {
        _ = try? store.updateSession(sessionId) { s in
            if let i = s.photos.firstIndex(where: { $0.photoId == photoId }) { s.photos[i].mask = mask }
        }
    }

    /// 選んだ物でマスクを作って保存する（何も選ばなければ noObject）。
    private func saveSelection(sessionId: String, photo: Photo, analysis: InstanceAnalysis, selected: [Int], selection: MaskSelectionKind) throws {
        let count = analysis.instanceCount
        guard !selected.isEmpty else {
            setMask(sessionId: sessionId, photoId: photo.photoId, MaskInfo(status: .noObject, method: MaskInfo.visionMethod, instanceCount: count, selection: selection))
            try? FileManager.default.removeItem(at: store.maskURL(sessionId, photoId: photo.photoId))
            return
        }
        let result = try MaskGenerator.maskPNG(analysis: analysis, instances: selected)
        guard result.width == photo.image.width, result.height == photo.image.height else {
            setMask(sessionId: sessionId, photoId: photo.photoId, .failed("maskSizeMismatch \(result.width)x\(result.height)", instanceCount: count))
            return
        }
        try store.saveMask(sessionId: sessionId, photoId: photo.photoId, pngData: result.png, mask: MaskInfo(
            status: .candidate, width: result.width, height: result.height, method: MaskInfo.visionMethod,
            instanceCount: count, selectedInstances: selected, selection: selection
        ))
    }

    // MARK: 確認画面から

    /// 対象を選び直すための解析（物の番号の画像）。
    func analyzeForEditing(sessionId: String, photoId: String, completion: @escaping @MainActor (Result<InstanceAnalysis, Error>) -> Void) {
        let url = store.photoURL(sessionId, photoId: photoId)
        queue.async {
            let result = Result { try MaskGenerator.analyze(imageURL: url) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// ユーザーが選んだ物でマスクを作り直す（selection = user、status = candidate）。
    func applyUserSelection(sessionId: String, photoId: String, analysis: InstanceAnalysis, selected: [Int], completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var failure: Error?
            autoreleasepool {
                do {
                    guard let photo = try self.store.loadSession(sessionId).photo(id: photoId) else { throw SessionStoreError.photoNotFound(photoId) }
                    try self.saveSelection(sessionId: sessionId, photo: photo, analysis: analysis, selected: selected, selection: .user)
                } catch {
                    failure = error
                }
            }
            self.notify(sessionId)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    private func round(_ value: Double, _ digits: Int) -> Double {
        let p = pow(10, Double(digits))
        return (value * p).rounded() / p
    }
}
