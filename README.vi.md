# Agent Profiles

**Chạy Claude Code với bất kỳ nhà cung cấp AI nào, mỗi nhà một profile riêng.**

[English](README.md) · Tiếng Việt

<p align="center">
  <img src="docs/images/main-vi.png" alt="Agent Profiles: danh sách profile bên trái và cài đặt của profile đang chọn bên phải" width="760">
</p>

Claude Code dùng được với nhiều nhà cung cấp AI chứ không chỉ một. Vướng ở chỗ mỗi nhà cung cấp
cần địa chỉ, key và tên model riêng, nên việc chuyển qua lại thường phải sửa cài đặt bằng tay
hoặc giữ một đống script.

Agent Profiles biến mỗi nhà cung cấp thành một **profile** bạn tạo được trong một phút. Mỗi
profile có một lệnh riêng. Gõ `claude-work-glm` ở terminal nào cũng là bạn đang làm việc với
nhà cung cấp đó. Gõ `claude-side-deepseek` là bạn làm việc với nhà khác. Key của bạn được giữ an
toàn, và Claude Code thông thường của bạn không bị đụng tới.

## Bạn nhận được gì

- **Một profile cho mỗi nhà cung cấp.** Đặt tên, nhập địa chỉ, key và model. Xong.
- **Một lệnh cho mỗi profile.** Lệnh đặt theo tên profile (bạn đổi tên được) và chạy được ở
  terminal nào, thư mục nào.
- **Mẫu có sẵn** cho OpenRouter, DeepSeek, Kimi, GLM, MiniMax và proxy nội bộ. Chọn một mẫu là
  địa chỉ tự điền.
- **Key nằm trong Keychain của macOS.** Key không bao giờ được lưu trong file thường.
- **Claude Code của bạn vẫn như cũ.** Mỗi profile có cài đặt và lịch sử riêng, nên không có gì
  lẫn từ profile này sang profile khác. Nếu muốn, bạn có thể dùng chung hướng dẫn, kỹ năng và
  agent cho tất cả.
- **Có chấm cho biết kết nối có chạy không.** *Kiểm tra kết nối* nhờ CLI trả lời một câu ngắn, giống cách lệnh của
  bạn làm, và nói chỗ nào sai: key, địa chỉ, tên model, đăng nhập hay mạng. Kết quả được giữ giữa các lần mở, nên bạn
  thấy ngay trạng thái của mọi profile khi mở ứng dụng.
- **Chọn model từ danh sách.** Gõ tên model nào cũng được, hoặc chọn từ những model nhà cung cấp
  đưa ra.
- **Mở ngay chỗ bạn làm việc.** Chạy profile trong Terminal hoặc iTerm2, vào thẳng thư mục dự án.
- **Xóa sạch.** Xóa một profile là mọi thứ thuộc về nó đi theo.
- **Tiếng Anh và tiếng Việt**, giao diện sáng hoặc tối theo máy của bạn.
- **Tự cập nhật.** App báo khi có bản mới và cài bằng một cú bấm, sau khi kiểm tra bản đó thật sự
  đến từ chúng tôi.

<p align="center">
  <img src="docs/images/main-light.png" alt="Cùng cửa sổ đó ở giao diện sáng" width="560">
  &nbsp;
  <img src="docs/images/settings-vi.png" alt="Cửa sổ cài đặt: ngôn ngữ, giao diện, terminal và cập nhật" width="230">
</p>

## Cài đặt

Bạn cần một máy Mac **Apple Silicon** chạy **macOS 14 trở lên**.

1. Tải file `Agent-Profiles-<phiên bản>.dmg` mới nhất ở
   [trang Releases](https://github.com/tamnt1707/agent-profiles/releases/latest).
2. Mở file và kéo **Agent Profiles** vào **Applications**.
3. Lần đầu, bấm chuột phải vào app rồi chọn **Mở**. macOS chỉ hỏi một lần, vì app chưa được Apple
   notarize.

## Bắt đầu trong ba bước

1. Bấm **+**, chọn một mẫu nhà cung cấp (hoặc bắt đầu từ trống) và gõ tên.
2. Dán key và bấm **Kiểm tra kết nối**. Rồi **Lưu**.
3. Bấm **Mở trong terminal**, hoặc gõ lệnh của profile ở terminal bất kỳ.

Khi bạn lưu profile đầu tiên, app hỏi có làm cho các lệnh chạy được ở mọi terminal không. App
luôn hỏi trước, và bạn hoàn tác được bất cứ lúc nào trong phần cài đặt.

## Câu hỏi thường gặp

**Key của tôi có an toàn không?**
Key được lưu trong Keychain của macOS, cùng chỗ máy Mac giữ mật khẩu. Key không bao giờ được ghi ra
file, và chỉ được gửi đến địa chỉ bạn đã nhập cho profile đó.

**Có làm thay đổi cách Claude Code thông thường của tôi không?**
Không. Cài đặt Claude Code của bạn được để yên. Mỗi profile có một không gian riêng.

**Dùng được với nhà cung cấp nào?**
Bất kỳ nhà cung cấp nào có địa chỉ tương thích Claude. Các mẫu có sẵn phủ những nhà phổ biến, còn
địa chỉ khác bạn gõ tay.

**Kiểm tra kết nối tốn bao nhiêu?**
Một yêu cầu ngắn qua CLI: khoảng 1.500 token vào và vài token ra. Ứng dụng cũng làm vậy một lần cho profile chưa có
kết quả khi mở; kết quả được giữ cho đến khi profile thay đổi hoặc bạn kiểm tra lại. Bạn có thể tắt việc kiểm tra khi
mở trong Cài đặt.

**Xóa một profile thì chuyện gì xảy ra?**
Key, lệnh và lịch sử đã lưu của nó đều bị xóa. Nếu đó là profile cuối cùng, app cũng hỏi có gỡ phần
thiết lập terminal mà nó đã thêm không.

**Có chạy trên Mac Intel không?**
Chưa. Phiên bản 0.1 chỉ chạy trên Apple Silicon.

## Xem thêm

- [Có gì mới ở mỗi phiên bản](CHANGELOG.md)
- [Tự build app](docs/BUILDING.md)

Agent Profiles là một dự án độc lập. Dự án không do Anthropic hay các nhà cung cấp mà nó kết nối
tạo ra, và cũng không liên kết với họ. Mọi tên sản phẩm thuộc về chủ sở hữu của chúng.
