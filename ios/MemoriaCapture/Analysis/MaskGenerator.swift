import CaptureCore
import CoreVideo
import Foundation
import Vision

enum MaskGeneratorError: LocalizedError {
    case simulatorUnsupported
    case visionFailed(String)
    case pixelFormat(OSType)
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported: return "simulatorUnsupported"
        case .visionFailed(let message): return "vision: \(message)"
        case .pixelFormat(let format): return "unexpectedPixelFormat \(format)"
        case .encodeFailed: return "pngEncodeFailed"
        }
    }
}

/// 写真 1 枚の Vision の結果（物の番号の画像を持つ）。マスクを作り直すときに使い回す。
final class InstanceAnalysis: @unchecked Sendable {
    let imageURL: URL
    let handler: VNImageRequestHandler
    let observation: VNInstanceMaskObservation?
    let labelMap: InstanceLabelMap?

    init(imageURL: URL, handler: VNImageRequestHandler, observation: VNInstanceMaskObservation?, labelMap: InstanceLabelMap?) {
        self.imageURL = imageURL
        self.handler = handler
        self.observation = observation
        self.labelMap = labelMap
    }

    var instanceCount: Int { observation?.allInstances.count ?? 0 }
}

/// VNGenerateForegroundInstanceMaskRequest（iOS 17）で作品のマスクを作る。
/// 保存した写真（センサーの向き、EXIF 1）をそのまま `.up` で渡すので、マスクも写真と同じ向き・大きさになる。
enum MaskGenerator {
    static func analyze(imageURL: URL) throws -> InstanceAnalysis {
        #if targetEnvironment(simulator)
        throw MaskGeneratorError.simulatorUnsupported
        #else
        let handler = VNImageRequestHandler(url: imageURL, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw MaskGeneratorError.visionFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first else {
            return InstanceAnalysis(imageURL: imageURL, handler: handler, observation: nil, labelMap: nil)
        }
        return InstanceAnalysis(imageURL: imageURL, handler: handler, observation: observation, labelMap: try labelMap(observation.instanceMask))
        #endif
    }

    /// 物の番号の画像（OneComponent8）を写す。
    private static func labelMap(_ buffer: CVPixelBuffer) throws -> InstanceLabelMap {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 else { throw MaskGeneratorError.pixelFormat(format) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskGeneratorError.pixelFormat(format) }
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { labels[y * width + x] = pointer[y * bytesPerRow + x] }
        }
        return InstanceLabelMap(labels: labels, width: width, height: height)
    }

    /// 選んだ物だけのマスク（写真と同じ大きさ、8 bit グレー、255 = 作品）の PNG。
    static func maskPNG(analysis: InstanceAnalysis, instances: [Int]) throws -> (png: Data, width: Int, height: Int) {
        guard let observation = analysis.observation else { throw MaskGeneratorError.visionFailed("noObservation") }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(instances), from: analysis.handler)
        } catch {
            throw MaskGeneratorError.visionFailed(error.localizedDescription)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MaskGeneratorError.pixelFormat(format) }
        var pixels = [UInt8](repeating: 0, count: width * height)
        switch format {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width where row[x] >= 0.5 { pixels[y * width + x] = 255 }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where row[x] >= 128 { pixels[y * width + x] = 255 }
            }
        default:
            throw MaskGeneratorError.pixelFormat(format)
        }
        guard let png = ImageLoading.grayPNG(pixels: pixels, width: width, height: height) else { throw MaskGeneratorError.encodeFailed }
        return (png, width, height)
    }
}
