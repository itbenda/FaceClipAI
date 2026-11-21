import Foundation
import Accelerate

struct Exemplar: Codable, Hashable {
    var e: [Float]
    var q: Float
}

struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var isIgnored = false
    var exemplars: [Exemplar] = []
}

/// One person-track inside one video (faces of the same person merged across frames).
struct FaceRecord: Codable, Identifiable {
    var id = UUID()
    var assetId: String
    var times: [Double]
    var embedding: [Float]
    var quality: Float
    var size: Float
    var thumb: Data
    var personId: UUID?
    var manual = false
    var rejected: [UUID] = []
}

struct VideoRecord: Codable {
    var assetId: String
    var scannedAt: Date
    var duration: Double
    var faceCount: Int
}

struct Database: Codable {
    var persons: [Person] = []
    var faces: [FaceRecord] = []
    var videos: [String: VideoRecord] = [:]
    var matchThreshold: Float = 0.55
    var sampleInterval: Double = 0.5
}

struct FaceCluster: Identifiable {
    let id = UUID()
    var faceIds: [UUID]
    var assetIds: Set<String>
}

struct ScanProgress {
    var total: Int
    var done: Int
    var current: String
    var faces: Int
}

enum Vec {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return vDSP.dot(a, b)
    }

    static func normalize(_ v: [Float]) -> [Float] {
        let n = sqrt(vDSP.sumOfSquares(v))
        return n > 0 ? vDSP.divide(v, n) : v
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        vDSP.add(a, b)
    }
}

enum Clustering {
    /// Greedy leader clustering on L2-normalised embeddings.
    static func cluster(_ faces: [FaceRecord], threshold: Float) -> [FaceCluster] {
        var sums: [[Float]] = []
        var centroids: [[Float]] = []
        var members: [[UUID]] = []
        var assets: [Set<String>] = []

        for f in faces.sorted(by: { $0.quality > $1.quality }) {
            var best = -1
            var bestSim: Float = -2
            for (i, c) in centroids.enumerated() {
                let s = Vec.dot(c, f.embedding)
                if s > bestSim { bestSim = s; best = i }
            }
            if best >= 0, bestSim >= threshold {
                sums[best] = Vec.add(sums[best], f.embedding)
                centroids[best] = Vec.normalize(sums[best])
                members[best].append(f.id)
                assets[best].insert(f.assetId)
            } else {
                sums.append(f.embedding)
                centroids.append(f.embedding)
                members.append([f.id])
                assets.append([f.assetId])
            }
        }

        return members.indices
            .map { FaceCluster(faceIds: members[$0], assetIds: assets[$0]) }
            .sorted {
                ($0.assetIds.count, $0.faceIds.count) > ($1.assetIds.count, $1.faceIds.count)
            }
    }
}

func formatTime(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}
