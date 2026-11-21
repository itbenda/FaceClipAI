# FaceClip ⚽

App iPhone (dùng cá nhân) quét video đá bóng trong thư viện Ảnh, nhận diện ai xuất hiện, gom video theo từng người và gửi bản gốc qua Slack bằng share sheet. Mọi thứ chạy trên máy, không upload video đi đâu.

- Tìm khuôn mặt: Apple Vision (Neural Engine)
- Nhận diện: FaceNet (InceptionResnetV1, VGGFace2) chuyển sang Core ML
- Không cần Mac: build trên GitHub Actions (macOS runner), cài lên iPhone từ Windows bằng **Sideloadly**

## 1. Build IPA trên GitHub (một lần mỗi khi sửa code)

1. Tạo repo mới trên GitHub, ví dụ `faceclip`.
   - **Public**: không giới hạn phút build macOS.
   - **Private**: gói Free có 2000 phút/tháng, nhưng máy macOS tính gấp 10 → còn khoảng 200 phút, đủ cho khoảng 15–20 lần build.
2. Push code từ thư mục này:
   ```powershell
   git init -b main
   git add .
   git commit -m "FaceClip MVP"
   git remote add origin https://github.com/<user>/faceclip.git
   git push -u origin main
   ```
3. Mở tab **Actions** → workflow **Build IPA** sẽ tự chạy. Lần đầu mất khoảng 15 phút vì phải chuyển model; từ lần sau model đã được cache.
4. Build xong, tải artifact **FaceClip-ipa** (file zip) và giải nén ra `FaceClip.ipa`.

## 2. Cài lên iPhone bằng Sideloadly (Windows)

1. Cài **iTunes bản tải từ apple.com** (không dùng bản Microsoft Store) và **Sideloadly** (sideloadly.io).
2. Cắm iPhone vào máy, trên iPhone bấm *Tin cậy máy tính này*.
3. Mở Sideloadly, kéo `FaceClip.ipa` vào, nhập Apple ID (nên dùng một Apple ID phụ), bấm **Start**.
4. Trên iPhone:
   - Vào **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển → Bật**. Máy sẽ khởi động lại.
   - Vào **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị** → tin cậy Apple ID vừa dùng.
5. ⚠️ Apple ID miễn phí: app **hết hạn sau 7 ngày**. Muốn dùng tiếp thì cắm máy và bấm Start lại trong Sideloadly; dữ liệu trong app vẫn giữ nguyên. Sideloadly có chế độ tự ký lại qua Wi-Fi nếu PC đang bật.

## 3. Sử dụng

1. **Quét**: chọn khoảng ngày → *Bắt đầu quét*. Nên cắm sạc nếu quét nhiều video.
2. **Chưa biết**: app gom các khuôn mặt giống nhau thành nhóm. Bấm vào nhóm, đặt tên (hoặc chọn *Bỏ qua* cho người lạ / đội bạn). Chạm vào khuôn mặt bị gom nhầm để loại ra.
3. Từ lần quét sau, người đã đặt tên được **tự nhận ra**.
4. **Người**: chọn một người → tick video → **Gửi** → chọn Slack → chọn DM của người đó. App gửi file gốc, không bị nén.
   - Nhấn giữ một video → *Không phải X* nếu app nhận nhầm.
   - Menu ⋯ → *Thêm vào album "⚽ Tên"* để có album trong app Ảnh (không tốn thêm dung lượng).
5. Nếu nhận nhầm nhiều thì tăng *Ngưỡng nhận diện*; nếu sót nhiều thì giảm ngưỡng hoặc chuyển lấy mẫu lên 4 khung/giây.

## Giới hạn hiện tại

- Mặt quá nhỏ (dưới khoảng 36px ở khung 1080p, tức người đứng rất xa) sẽ bị bỏ qua. Quay 4K hoặc zoom gần sẽ nhận diện tốt hơn.
- Chưa chạy nền: app phải mở trong lúc quét.
- Model FaceNet/VGGFace2 chỉ cho dùng phi thương mại. Dùng cá nhân thì không sao.

## Cấu trúc

```
App/                 Mã Swift (SwiftUI)
  FaceEngine.swift   Vision + Core ML: tìm mặt → tạo embedding 512 chiều
  VideoScanner.swift Lấy frame, gom mặt cùng người trong một video
  AppStore.swift     Dữ liệu, so khớp người, gom nhóm, điều phối quét
  PhotoService.swift PhotoKit: đọc video, xuất file gốc, tạo album
  Views/             Các màn hình Quét / Người / Chưa biết
tools/convert_model.py  Chuyển FaceNet PyTorch → Core ML (chạy trong CI)
project.yml          Cấu hình XcodeGen (CI tự sinh .xcodeproj)
.github/workflows/build.yml
```
