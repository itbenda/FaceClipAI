import Photos
import PhotosUI
import SwiftUI

struct ScanView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var pending = 0
    @State private var confirmReset = false
    @State private var confirmClearImported = false
    @State private var permissionLog: [String] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var askedOnLaunch = false

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
                Section {
                    PhotosPicker(selection: $pickerItems,
                                 matching: .videos,
                                 preferredItemEncoding: .current,
                                 photoLibrary: .shared()) {
                        Label("Chọn video để quét", systemImage: "film.stack")
                    }
                    .disabled(store.scanProgress != nil)
                } header: {
                    Text("Chọn video")
                } footer: {
                    Text("Không cần cấp quyền Ảnh. App giữ bản sao gốc (không nén) để gửi Slack; xoá bản sao ở mục Thống kê khi không cần nữa.")
                }

                if let p = store.scanProgress {
                    Section("Đang quét") {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            Text("\(p.done)/\(p.total) video · \(p.faces) khuôn mặt")
                                .font(.subheadline)
                            Text(p.current).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Dừng", role: .destructive) { store.stopScan() }
                    }
                }

                if let info = store.info {
                    Section { Text(info) }
                }
                if let err = store.lastError {
                    Section("Lỗi") { Text(err).foregroundStyle(.red) }
                }

                Section {
                    if !authorized {
                        Button(auth == .notDetermined ? "Cấp quyền truy cập Ảnh" : "Mở Cài đặt để cấp quyền Ảnh") {
                            requestPhotos()
                        }
                    }
                    DatePicker("Từ ngày", selection: $from, displayedComponents: .date)
                    DatePicker("Đến ngày", selection: $to, displayedComponents: .date)
                    LabeledContent("Video chưa quét", value: "\(pending)")
                    Button {
                        store.startScan(from: rangeStart, to: rangeEnd)
                    } label: {
                        Label("Quét theo khoảng ngày", systemImage: "play.fill")
                    }
                    .disabled(!authorized || pending == 0 || store.scanProgress != nil)
                } header: {
                    Text("Quét tự động theo ngày (cần quyền Ảnh)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if auth == .restricted {
                            Text("iOS đang chặn quyền Ảnh (Thời gian sử dụng hoặc hồ sơ quản lý thiết bị).")
                        } else if auth == .denied {
                            Text("Quyền Ảnh đang bị tắt. Vào Cài đặt → FaceClip → Ảnh → chọn \"Truy cập toàn bộ\".")
                        }
                        Text("Trạng thái quyền: \(authLabel) (\(auth.rawValue))")
                            .font(.caption2.monospaced())
                        ForEach(permissionLog, id: \.self) { line in
                            Text(line).font(.caption2.monospaced())
                        }
                    }
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
                    LabeledContent("Bản sao video đã chọn", value: store.importedSizeText)
                    Button("Xoá bản sao video đã chọn", role: .destructive) { confirmClearImported = true }
                    Button("Xoá toàn bộ dữ liệu", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Quét video")
            .task(id: "\(rangeStart)-\(rangeEnd)-\(store.db.videos.count)-\(auth.rawValue)") {
                pending = authorized ? store.pendingVideos(from: rangeStart, to: rangeEnd).count : 0
            }
            .task {
                // Ask once on first launch; some setups only show the prompt this way.
                guard !askedOnLaunch else { return }
                askedOnLaunch = true
                if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                    requestPhotos()
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                store.scanPicked(items)
                pickerItems = []
            }
            .confirmationDialog("Xoá toàn bộ người và kết quả quét?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("Xoá", role: .destructive) { store.resetAll() }
            }
            .confirmationDialog("Xoá bản sao video đã chọn? Kết quả nhận diện của các video này cũng bị xoá.",
                                isPresented: $confirmClearImported, titleVisibility: .visible) {
                Button("Xoá", role: .destructive) { store.clearImported() }
            }
            .onAppear { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            .onChange(of: scenePhase) { _, phase in
                // user may have changed the permission in Settings
                if phase == .active { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
        }
    }

    private func log(_ s: String) {
        let t = Date().formatted(date: .omitted, time: .standard)
        permissionLog = Array((permissionLog + ["\(t) \(s)"]).suffix(4))
    }

    private func requestPhotos() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log("bấm xin quyền, hiện tại=\(current.rawValue)")
        if current == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    log("kết quả readWrite=\(status.rawValue)")
                    auth = status
                    if status == .notDetermined {
                        // fallback: legacy API
                        PHPhotoLibrary.requestAuthorization { legacy in
                            DispatchQueue.main.async {
                                log("kết quả legacy=\(legacy.rawValue)")
                                auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                            }
                        }
                    }
                }
            }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            auth = current
            UIApplication.shared.open(url)
        }
    }
}
