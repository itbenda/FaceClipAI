import SwiftUI

struct UnknownView: View {
    @EnvironmentObject var store: AppStore
    @State private var picked: FaceCluster?

    var body: some View {
        NavigationStack {
            List(store.clusters) { c in
                Button {
                    picked = c
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: -8) {
                            ForEach(c.faceIds.prefix(6), id: \.self) { id in
                                FaceThumb(data: store.face(id)?.thumb, size: 48)
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            }
                        }
                        Text("\(c.assetIds.count) video · \(c.faceIds.count) lần xuất hiện")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if store.clusters.isEmpty {
                    ContentUnavailableView("Không còn khuôn mặt lạ", systemImage: "checkmark.circle",
                                           description: Text("Mọi khuôn mặt đã được gán tên."))
                }
            }
            .navigationTitle("Đây là ai?")
            .sheet(item: $picked) { c in
                ClusterSheet(cluster: c)
            }
        }
    }
}

struct ClusterSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let cluster: FaceCluster
    @State private var name = ""
    @State private var excluded: Set<UUID> = []

    private var included: [UUID] { cluster.faceIds.filter { !excluded.contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                        ForEach(cluster.faceIds, id: \.self) { id in
                            FaceThumb(data: store.face(id)?.thumb, size: 64)
                                .opacity(excluded.contains(id) ? 0.25 : 1)
                                .overlay(alignment: .bottomTrailing) {
                                    if excluded.contains(id) {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                    }
                                }
                                .onTapGesture {
                                    if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Chạm vào khuôn mặt bị nhầm để loại ra.")
                }

                Section("Người mới") {
                    TextField("Tên (vd: Tuấn)", text: $name)
                    Button("Lưu") {
                        store.createPerson(name: name, faceIds: included)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || included.isEmpty)
                }

                if !store.visiblePersons.isEmpty {
                    Section("Hoặc là người đã có") {
                        ForEach(store.visiblePersons) { p in
                            Button {
                                store.assign(faceIds: included, to: p.id)
                                dismiss()
                            } label: {
                                HStack {
                                    FaceThumb(data: store.avatar(for: p.id), size: 32)
                                    Text(p.name)
                                }
                            }
                            .disabled(included.isEmpty)
                        }
                    }
                }

                Section {
                    Button("Bỏ qua (người lạ / đội bạn)", role: .destructive) {
                        store.ignore(faceIds: included)
                        dismiss()
                    }
                    .disabled(included.isEmpty)
                }
            }
            .navigationTitle("Đây là ai?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
        }
    }
}
