import CoreGraphics
import CoreML
import UIKit
import Vision

enum EngineError: LocalizedError {
    case modelMissing, badModel

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Không tìm thấy FaceNet.mlmodelc trong app"
        case .badModel: return "Model không có input ảnh 'input'"
        }
    }
}

struct DetectedFace {
    let embedding: [Float]
    let quality: Float
    let size: Float
    let crop: CGImage
}

/// Face detection (Apple Vision) + embedding (FaceNet Core ML). Not thread-safe; use from one task.
final class FaceEngine {
    private let model: MLModel
    private let constraint: MLImageConstraint
    var minFaceSize: CGFloat = 36
    var minQuality: Float = 0.15

    init() throws {
        guard let url = Bundle.main.url(forResource: "FaceNet", withExtension: "mlmodelc") else {
            throw EngineError.modelMissing
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: cfg)
        guard let c = model.modelDescription.inputDescriptionsByName["input"]?.imageConstraint else {
            throw EngineError.badModel
        }
        constraint = c
    }

    func process(frame: CGImage) -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: frame, orientation: .up, options: [:])
        let detect = VNDetectFaceRectanglesRequest()
        do { try handler.perform([detect]) } catch { return [] }

        let W = CGFloat(frame.width), H = CGFloat(frame.height)
        let faces = (detect.results ?? []).filter {
            $0.boundingBox.width * W >= minFaceSize && $0.boundingBox.height * H >= minFaceSize
        }
        guard !faces.isEmpty else { return [] }

        let qualityReq = VNDetectFaceCaptureQualityRequest()
        qualityReq.inputFaceObservations = faces
        try? handler.perform([qualityReq])
        let observed = qualityReq.results ?? faces

        var out: [DetectedFace] = []
        for f in observed {
            let quality = f.faceCaptureQuality ?? 0.5
            if quality < minQuality { continue }
            guard let crop = cropFace(frame, box: f.boundingBox),
                  let emb = embed(crop) else { continue }
            out.append(DetectedFace(
                embedding: emb,
                quality: quality,
                size: Float(max(f.boundingBox.width * W, f.boundingBox.height * H)),
                crop: crop
            ))
        }
        return out
    }

    /// Square crop around the Vision box (normalised, bottom-left origin) with margin.
    private func cropFace(_ img: CGImage, box: CGRect) -> CGImage? {
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let w = box.width * W, h = box.height * H
        let cx = box.midX * W
        let cy = (1 - box.midY) * H
        let side = max(w, h) * 1.3
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            .integral
        guard rect.width > 8, rect.height > 8 else { return nil }
        return img.cropping(to: rect)
    }

    private func embed(_ crop: CGImage) -> [Float]? {
        do {
            let value = try MLFeatureValue(cgImage: crop, constraint: constraint, options: nil)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input": value])
            let result = try model.prediction(from: provider)
            guard let arr = result.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var v = [Float](repeating: 0, count: arr.count)
            for i in 0..<arr.count { v[i] = arr[i].floatValue }
            return Vec.normalize(v)
        } catch {
            return nil
        }
    }

    static func thumbnail(_ crop: CGImage, side: CGFloat = 96) -> Data {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.75) ?? Data()
    }
}
