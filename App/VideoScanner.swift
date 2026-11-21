import AVFoundation
import Photos

/// Samples frames from a video and merges faces of the same person into tracks.
final class VideoScanner {
    private let engine: FaceEngine
    private let interval: Double
    private let trackThreshold: Float = 0.65

    private struct Track {
        var sum: [Float]
        var centroid: [Float]
        var times: [Double]
        var bestQuality: Float
        var size: Float
        var thumb: Data
    }

    init(engine: FaceEngine, interval: Double) {
        self.engine = engine
        self.interval = interval
    }

    func scan(asset: PHAsset) async throws -> (VideoRecord, [FaceRecord]) {
        let av = try await PhotoService.avAsset(for: asset)
        return try await scan(av: av, id: asset.localIdentifier)
    }

    func scan(av: AVAsset, id: String) async throws -> (VideoRecord, [FaceRecord]) {
        let duration = try await av.load(.duration).seconds

        let gen = AVAssetImageGenerator(asset: av)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        let tol = CMTime(seconds: interval / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        let last = max(duration - 0.05, 0)
        let times = stride(from: 0.0, through: last, by: interval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        var tracks: [Track] = []
        for await result in gen.images(for: times) {
            if Task.isCancelled { break }
            switch result {
            case .success(requestedTime: let t, image: let image, actualTime: _):
                let faces = autoreleasepool { engine.process(frame: image) }
                for f in faces { merge(f, time: t.seconds, into: &tracks) }
            case .failure:
                continue
            }
        }
        try Task.checkCancellation()

        let records = tracks
            .filter { $0.times.count >= 2 || $0.bestQuality >= 0.35 }
            .map {
                FaceRecord(assetId: id, times: $0.times, embedding: $0.centroid,
                           quality: $0.bestQuality, size: $0.size, thumb: $0.thumb)
            }
        let video = VideoRecord(assetId: id, scannedAt: Date(), duration: duration, faceCount: records.count)
        return (video, records)
    }

    private func merge(_ f: DetectedFace, time: Double, into tracks: inout [Track]) {
        var best = -1
        var bestSim: Float = -2
        for (i, t) in tracks.enumerated() {
            let s = Vec.dot(t.centroid, f.embedding)
            if s > bestSim { bestSim = s; best = i }
        }
        if best >= 0, bestSim >= trackThreshold {
            tracks[best].sum = Vec.add(tracks[best].sum, f.embedding)
            tracks[best].centroid = Vec.normalize(tracks[best].sum)
            if tracks[best].times.last != time { tracks[best].times.append(time) }
            if f.quality > tracks[best].bestQuality {
                tracks[best].bestQuality = f.quality
                tracks[best].size = f.size
                tracks[best].thumb = FaceEngine.thumbnail(f.crop)
            }
        } else {
            tracks.append(Track(sum: f.embedding, centroid: f.embedding, times: [time],
                                bestQuality: f.quality, size: f.size,
                                thumb: FaceEngine.thumbnail(f.crop)))
        }
    }
}
