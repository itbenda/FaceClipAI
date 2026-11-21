import AVFoundation
import CoreTransferable
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoError: LocalizedError {
    case noAVAsset, noResource, albumFailed

    var errorDescription: String? {
        switch self {
        case .noAVAsset: return "Không đọc được video"
        case .noResource: return "Không tìm thấy file video gốc"
        case .albumFailed: return "Không tạo được album"
        }
    }
}

private final class Box<T> { var value: T?; init() {} }

/// Video received from the system photo picker, copied (original encoding) into the app container.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = PhotoService.importedDir
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(UUID().uuidString.prefix(8))-\(received.file.lastPathComponent)"
            let dest = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum PhotoService {
    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func fetchVideos(from: Date, to: Date) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.video.rawValue, from as NSDate, to as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return collect(PHAsset.fetchAssets(with: opts))
    }

    static func assets(ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        return collect(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private static func collect(_ r: PHFetchResult<PHAsset>) -> [PHAsset] {
        var out: [PHAsset] = []
        out.reserveCapacity(r.count)
        r.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    static func avAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, info in
                if let av {
                    cont.resume(returning: av)
                } else {
                    cont.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? PhotoError.noAVAsset)
                }
            }
        }
    }

    static func thumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFill, options: o) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    // MARK: - Imported files (system picker)

    static var importedDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imported", isDirectory: true)
    }

    static func importedSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: importedDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func fileThumbnail(_ url: URL, size: CGSize) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = size
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - Share original file

    static var shareDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    }

    static func clearShareDir() {
        try? FileManager.default.removeItem(at: shareDir)
    }

    /// Copies the original (full quality, edits applied if any) video file to a temp URL for sharing.
    static func exportOriginal(_ asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .video }
        guard let res = resources.first(where: { $0.type == .fullSizeVideo }) ?? original else {
            throw PhotoError.noResource
        }
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let name = original?.originalFilename ?? res.originalFilename
        let dest = shareDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: res, toFile: dest, options: opts) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
        return dest
    }

    // MARK: - Albums

    static func addToAlbum(named name: String, assets: [PHAsset]) async throws {
        var album: PHAssetCollection?
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        all.enumerateObjects { c, _, stop in
            if c.localizedTitle == name { album = c; stop.pointee = true }
        }
        if album == nil {
            let placeholder = Box<String>()
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholder.value = req.placeholderForCreatedAssetCollection.localIdentifier
            }
            if let pid = placeholder.value {
                album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [pid], options: nil).firstObject
            }
        }
        guard let target = album else { throw PhotoError.albumFailed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: target)?.addAssets(assets as NSArray)
        }
    }
}
