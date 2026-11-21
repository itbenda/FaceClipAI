import Photos
import SwiftUI

struct ScanView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var pending = 0
    @State private var confirmReset = false

    private var authorized: Bool { auth == .authorized || auth == .limited }
    private var authLabel: String {
        switch auth {
        case .notDetermined: return "chưa hỏi"
        case .restricted: return "bị hệ thống chặn"
        case .denied: return "đã từ chối"
        case .authorized: return "toàn bộ"
        case .limited: return "giới hạn"
        @unknown default: return "khác"
        }
    }
    private var rangeStart: Date { Calendar.current.startOfDay(for: from) }
    private var rangeEnd: Date {
        Calendar.current.date(byAdding: DateComponents(day: 1, second: -1),
                              to: Calendar.current.startOfDay(for: to)) ?? to
    }

    var body: some View {
        NavigationStack {
            Form {
                if !authorized {
                    Section {
                        Button(auth == .notDetermined ? "Cấp quyền truy cập Ảnh" : "Mở Cài đặt để cấp quyền Ảnh") {
                            requestPhotos()
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(auth == .notDetermined
                                 ? "Video được xử lý hoàn toàn trên iPhone, không upload đi đâu."
                                 : auth == .restricted
                                 ? "iOS đang chặn quyền Ảnh (Thời gian sử dụng hoặc hồ sơ quản lý thiết bị). Kiểm tra Cài đặt → Thời gian sử dụng → Giới hạn nội dung & quyền riêng tư → Ảnh."
                                 : "Quyền Ảnh đang bị tắt. Vào Cài đặt → FaceClip → Ảnh → chọn \"Truy cập toàn bộ\".")
                            Text("Trạng thái quyền: \(authLabel) (\(auth.rawValue))")
                                .font(.caption2.monospaced())
                        }
                    }
                }

                Section("Khoảng thời gian") {
                    DatePicker("Từ ngày", selection: $from, displayedComponents: .date)
                    DatePicker("Đến ngày", selection: $to, displayedComponents: .date)
                    LabeledContent("Video chưa quét", value: "\(pending)")
                }

                Section {
                    if let p = store.scanProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            Text("\(p.done)/\(p.total) video · \(p.faces) khuôn mặt")
                                .font(.subheadline)
                            Text(p.current).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Dừng", role: .destructive) { store.stopScan() }
                    } else {
                        Button {
                            store.startScan(from: rangeStart, to: rangeEnd)
                        } label: {
                            Label("Bắt đầu quét", systemImage: "play.fill")
                        }
                        .disabled(!authorized || pending == 0)
                    }
                } footer: {
                    Text("Màn hình sẽ luôn sáng trong lúc quét. Nên cắm sạc nếu quét nhiều video.")
                }

                if let info = store.info {
                    Section { Text(info) }
                }
                if let err = store.lastError {
                    Section("Lỗi") { Text(err).foregroundStyle(.red) }
                }

                Section("Cài đặt") {
                    Picker("Lấy mẫu", selection: $store.db.sampleInterval) {
                        Text("4 khung/giây").tag(0.25)
                        Text("2 khung/giây").tag(0.5)
                        Text("1 khung/giây").tag(1.0)
                    }
                    VStack(alignment: .leading) {
                        Text("Ngưỡng nhận diện: \(store.db.matchThreshold, specifier: "%.2f")")
                        Slider(
                            value: Binding(
                                get: { Double(store.db.matchThreshold) },
                                set: { store.db.matchThreshold = Float($0) }
                            ),
                            in: 0.4...0.8, step: 0.01,
                            onEditingChanged: { editing in
                                if !editing { store.rematchAll() }
                            }
                        )
                        Text("Thấp hơn = nhận được nhiều hơn nhưng dễ nhầm. Cao hơn = chắc chắn hơn nhưng dễ sót.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Thống kê") {
                    LabeledContent("Đã quét", value: "\(store.db.videos.count) video")
                    LabeledContent("Khuôn mặt", value: "\(store.db.faces.count)")
                    LabeledContent("Người đã đặt tên", value: "\(store.visiblePersons.count)")
                    Button("Xoá toàn bộ dữ liệu", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Quét video")
            .task(id: "\(rangeStart)-\(rangeEnd)-\(store.db.videos.count)-\(auth.rawValue)") {
                pending = authorized ? store.pendingVideos(from: rangeStart, to: rangeEnd).count : 0
            }
            .confirmationDialog("Xoá toàn bộ người và kết quả quét?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Xoá", role: .destructive) { store.resetAll() }
            }
            .onAppear { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            .onChange(of: scenePhase) { _, phase in
                // user may have changed the permission in Settings
                if phase == .active { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
        }
    }

    private func requestPhotos() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { auth = status }
            }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            auth = current
            UIApplication.shared.open(url)
        }
    }
}
