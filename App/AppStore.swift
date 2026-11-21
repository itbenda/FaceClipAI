import Foundation
import Photos
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published var db = Database()
    @Published private(set) var clusters: [FaceCluster] = []
    @Published var scanProgress: ScanProgress?
    @Published var lastError: String?
    @Published var info: String?

    private let url: URL
    private let saveQueue = DispatchQueue(label: "faceclip.save", qos: .utility)
    private var scanTask: Task<Void, Never>?
    private var engine: FaceEngine?
    private let clusterThreshold: Float = 0.6
    private let maxExemplars = 25
    private let ignoredName = "Người lạ (bỏ qua)"

    init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("db.plist")
        load()
        refreshClusters()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            db = try PropertyListDecoder().decode(Database.self, from: data)
        } catch {
            lastError = "Không đọc được dữ liệu cũ: \(error.localizedDescription)"
        }
    }

    func save() {
        let snapshot = db
        let url = self.url
        // serial queue: writes land in order, so an older snapshot never overwrites a newer one
        saveQueue.async {
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Queries

    var visiblePersons: [Person] {
        db.persons.filter { !$0.isIgnored }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func face(_ id: UUID) -> FaceRecord? {
        db.faces.first { $0.id == id }
    }

    func assetIds(for personId: UUID) -> [String] {
        Array(Set(db.faces.lazy.filter { $0.personId == personId }.map(\.assetId))).sorted()
    }

    func firstSeen(_ personId: UUID, in assetId: String) -> Double? {
        db.faces.lazy
            .filter { $0.personId == personId && $0.assetId == assetId }
            .compactMap { $0.times.min() }
            .min()
    }

    func avatar(for personId: UUID) -> Data? {
        db.faces.lazy.filter { $0.personId == personId }.max { $0.quality < $1.quality }?.thumb
    }

    // MARK: - Matching

    private func match(_ emb: [Float], rejected: [UUID]) -> UUID? {
        var bestId: UUID?
        var bestSim: Float = -2
        for p in db.persons where !rejected.contains(p.id) {
            for ex in p.exemplars {
                let s = Vec.dot(ex.e, emb)
                if s > bestSim { bestSim = s; bestId = p.id }
            }
        }
        return bestSim >= db.matchThreshold ? bestId : nil
    }

    func rematchAll() {
        for i in db.faces.indices where !db.faces[i].manual {
            db.faces[i].personId = match(db.faces[i].embedding, rejected: db.faces[i].rejected)
        }
        refreshClusters()
        save()
    }

    func refreshClusters() {
        let unknown = db.faces.filter { $0.personId == nil }
        clusters = Clustering.cluster(unknown, threshold: clusterThreshold)
    }

    // MARK: - Labeling

    func createPerson(name: String, faceIds: [UUID]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = db.persons.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            assign(faceIds: faceIds, to: existing.id)
            return
        }
        let p = Person(name: trimmed)
        db.persons.append(p)
        assign(faceIds: faceIds, to: p.id)
    }

    func ignore(faceIds: [UUID]) {
        if let p = db.persons.first(where: { $0.isIgnored }) {
            assign(faceIds: faceIds, to: p.id)
        } else {
            let p = Person(name: ignoredName, isIgnored: true)
            db.persons.append(p)
            assign(faceIds: faceIds, to: p.id)
        }
    }

    func assign(faceIds: [UUID], to personId: UUID) {
        let ids = Set(faceIds)
        var picked: [FaceRecord] = []
        for i in db.faces.indices where ids.contains(db.faces[i].id) {
            db.faces[i].personId = personId
            db.faces[i].manual = true
            db.faces[i].rejected.removeAll { $0 == personId }
            picked.append(db.faces[i])
        }
        addExemplars(from: picked, to: personId)
        rematchAll()
    }

    private func addExemplars(from faces: [FaceRecord], to personId: UUID) {
        guard let pi = db.persons.firstIndex(where: { $0.id == personId }) else { return }
        var ex = db.persons[pi].exemplars
        for f in faces.sorted(by: { $0.quality > $1.quality }) {
            // keep exemplars diverse: skip near-duplicates
            if ex.contains(where: { Vec.dot($0.e, f.embedding) > 0.92 }) { continue }
            ex.append(Exemplar(e: f.embedding, q: f.quality))
        }
        if ex.count > maxExemplars {
            ex = Array(ex.sorted { $0.q > $1.q }.prefix(maxExemplars))
        }
        db.persons[pi].exemplars = ex
    }

    /// "This video is not X": detach faces of that video from the person and never match them to X again.
    func removeVideo(_ assetId: String, from personId: UUID) {
        for i in db.faces.indices where db.faces[i].assetId == assetId && db.faces[i].personId == personId {
            db.faces[i].rejected.append(personId)
            db.faces[i].personId = nil
            db.faces[i].manual = false
        }
        rematchAll()
    }

    func rename(_ personId: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = db.persons.firstIndex(where: { $0.id == personId }) else { return }
        db.persons[i].name = trimmed
        save()
    }

    func deletePerson(_ personId: UUID) {
        db.persons.removeAll { $0.id == personId }
        for i in db.faces.indices where db.faces[i].personId == personId {
            db.faces[i].personId = nil
            db.faces[i].manual = false
        }
        rematchAll()
    }

    func resetAll() {
        stopScan()
        db = Database()
        refreshClusters()
        save()
    }

    // MARK: - Scanning

    func pendingVideos(from: Date, to: Date) -> [PHAsset] {
        PhotoService.fetchVideos(from: from, to: to).filter { db.videos[$0.localIdentifier] == nil }
    }

    func startScan(from: Date, to: Date) {
        guard scanTask == nil else { return }
        lastError = nil
        info = nil
        let assets = pendingVideos(from: from, to: to)
        guard !assets.isEmpty else {
            info = "Không có video mới trong khoảng thời gian này."
            return
        }
        if engine == nil {
            do { engine = try FaceEngine() } catch {
                lastError = error.localizedDescription
                return
            }
        }
        guard let engine else { return }
        let scanner = VideoScanner(engine: engine, interval: db.sampleInterval)

        scanProgress = ScanProgress(total: assets.count, done: 0, current: "", faces: 0)
        UIApplication.shared.isIdleTimerDisabled = true

        scanTask = Task { [weak self] in
            for (i, asset) in assets.enumerated() {
                if Task.isCancelled { break }
                let label = asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "video"
                self?.scanProgress?.current = label
                do {
                    let (video, faces) = try await scanner.scan(asset: asset)
                    self?.ingest(video: video, faces: faces)
                } catch is CancellationError {
                    break
                } catch {
                    self?.lastError = "Lỗi khi quét \(label): \(error.localizedDescription)"
                }
                self?.scanProgress?.done = i + 1
            }
            self?.finishScan()
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    private func ingest(video: VideoRecord, faces: [FaceRecord]) {
        var faces = faces
        for i in faces.indices {
            faces[i].personId = match(faces[i].embedding, rejected: [])
        }
        db.faces.append(contentsOf: faces)
        db.videos[video.assetId] = video
        scanProgress?.faces += faces.count
        save()
    }

    private func finishScan() {
        scanTask = nil
        scanProgress = nil
        UIApplication.shared.isIdleTimerDisabled = false
        refreshClusters()
        save()
    }
}
