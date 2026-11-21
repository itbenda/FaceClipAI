import Photos
import SwiftUI

struct FaceThumb: View {
    let data: Data?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct PeopleView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack {
            List(store.visiblePersons) { p in
                NavigationLink(value: p.id) {
                    HStack(spacing: 12) {
                        FaceThumb(data: store.avatar(for: p.id))
                        VStack(alignment: .leading) {
                            Text(p.name).font(.headline)
                            Text("\(store.assetIds(for: p.id).count) video")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if store.visiblePersons.isEmpty {
                    ContentUnavailableView(
                        "Chưa có ai",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Quét video, rồi vào tab \"Chưa biết\" để đặt tên cho từng khuôn mặt."))
                }
            }
            .navigationTitle("Người")
            .navigationDestination(for: UUID.self) { id in
                PersonDetailView(personId: id)
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in PhotoService.clearShareDir() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct AssetThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: asset.localIdentifier) {
            image = await PhotoService.thumbnail(for: asset, size: CGSize(width: 300, height: 300))
        }
    }
}

struct VideoCell: View {
    let asset: PHAsset
    let selected: Bool
    let firstSeen: Double?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { AssetThumb(asset: asset) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Text(formatTime(asset.duration))
                    if let firstSeen { Text("· 👤\(formatTime(firstSeen))") }
                }
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(4)
                .shadow(radius: 2)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
            .overlay {
                if selected { Rectangle().stroke(Color.accentColor, lineWidth: 3) }
            }
            .contentShape(Rectangle())
    }
}

struct PersonDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let personId: UUID

    @State private var assets: [PHAsset] = []
    @State private var selected: Set<String> = []
    @State private var shareItem: ShareItem?
    @State private var busy: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var person: Person? { store.db.persons.first { $0.id == personId } }
    private var name: String { person?.name ?? "" }

    var body: some View {
        let ids = store.assetIds(for: personId)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                ForEach(assets, id: \.localIdentifier) { a in
                    VideoCell(asset: a,
                              selected: selected.contains(a.localIdentifier),
                              firstSeen: store.firstSeen(personId, in: a.localIdentifier))
                        .onTapGesture { toggle(a.localIdentifier) }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeVideo(a.localIdentifier, from: personId)
                            } label: {
                                Label("Không phải \(name)", systemImage: "person.fill.xmark")
                            }
                        }
                }
            }
            .padding(4)
        }
        .overlay {
            if assets.isEmpty { ContentUnavailableView("Chưa có video", systemImage: "video.slash") }
        }
        .overlay {
            if let busy {
                ProgressView(busy)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Chọn tất cả") { selected = Set(ids) }
                    Button("Bỏ chọn") { selected = [] }
                    Divider()
                    Button("Thêm vào album \"⚽ \(name)\"", systemImage: "rectangle.stack.badge.plus") {
                        makeAlbum()
                    }
                    Button("Đổi tên", systemImage: "pencil") { newName = name; renaming = true }
                    Button("Xoá người này", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    send()
                } label: {
                    Label("Gửi \(selected.count) video", systemImage: "square.and.arrow.up")
                }
                .disabled(selected.isEmpty || busy != nil)
            }
        }
        .task(id: ids) {
            assets = PhotoService.assets(ids: ids)
            selected = selected.intersection(ids)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(urls: item.urls)
        }
        .alert("Đổi tên", isPresented: $renaming) {
            TextField("Tên", text: $newName)
            Button("Lưu") { store.rename(personId, to: newName) }
            Button("Huỷ", role: .cancel) {}
        }
        .confirmationDialog("Xoá \(name)? Video sẽ quay về mục Chưa biết.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá", role: .destructive) {
                store.deletePerson(personId)
                dismiss()
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func send() {
        let chosen = assets.filter { selected.contains($0.localIdentifier) }
        PhotoService.clearShareDir()
        Task {
            var urls: [URL] = []
            for (i, a) in chosen.enumerated() {
                busy = "Đang lấy video gốc \(i + 1)/\(chosen.count)…"
                do {
                    urls.append(try await PhotoService.exportOriginal(a))
                } catch {
                    store.lastError = "Không lấy được video gốc: \(error.localizedDescription)"
                }
            }
            busy = nil
            if !urls.isEmpty { shareItem = ShareItem(urls: urls) }
        }
    }

    private func makeAlbum() {
        let chosen = selected.isEmpty ? assets : assets.filter { selected.contains($0.localIdentifier) }
        Task {
            busy = "Đang thêm vào album…"
            do {
                try await PhotoService.addToAlbum(named: "⚽ \(name)", assets: chosen)
            } catch {
                store.lastError = error.localizedDescription
            }
            busy = nil
        }
    }
}
