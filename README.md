# Claude Profiles

App desktop (Rust + egui) để quản lý nhiều profile nhà cung cấp cho Claude Code trên macOS.

- Mỗi profile có Base URL, model và API key riêng.
- API key chỉ nằm trong **macOS Keychain**, không ghi ra file.
- Mỗi profile tự sinh một lệnh `claude-<tên>` thay cho các file batch viết tay.
- Mỗi profile có thư mục cấu hình Claude riêng (`CLAUDE_CONFIG_DIR`), nên **`~/.claude` gốc và app Claude Desktop không bị đụng tới**.

## Build và cài

Cần Rust (rustup) và Xcode Command Line Tools.

```bash
cd claude-profiles
./build-mac.sh
```

Script build bản release, tạo `~/Applications/Claude Profiles.app` và ký ad-hoc. Sau đó mở app bằng Spotlight.

Để gọi lệnh profile từ mọi terminal, thêm thư mục `bin` vào PATH (chỉ cần làm một lần):

```bash
echo 'export PATH="$HOME/.claude-profiles/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Khi đang phát triển, bạn có thể chạy thẳng bằng `cargo run`.

## Dùng

1. Bấm **Thêm profile**, chọn mẫu nhà cung cấp (hoặc Tùy chỉnh), sau đó điền tên, Base URL, API key và model.
2. Bấm **Lưu**. App sẽ:
   - lưu key vào Keychain (service `claude-profiles`, account = tên lệnh của profile);
   - tạo `~/.claude-profiles/bin/claude-<tên>`;
   - tạo `~/.claude-profiles/homes/<tên>/` làm thư mục cấu hình riêng.
3. Bấm **Mở terminal với profile này**, hoặc gõ `claude-<tên>` trong bất kỳ terminal nào. Mọi tham số đều được chuyển tiếp, ví dụ `claude-glm --resume`.

Lần đầu một lệnh profile đọc key, macOS sẽ hỏi cho phép `security` truy cập Keychain. Chọn **Always Allow** để không bị hỏi lại.

Lần đầu app mở Terminal hoặc iTerm2, macOS sẽ hỏi quyền điều khiển ứng dụng (Automation). Chọn **OK**.

## Ánh xạ biến môi trường

| Trường trong app | Biến môi trường |
|---|---|
| Base URL | `ANTHROPIC_BASE_URL` |
| Bearer token | `ANTHROPIC_AUTH_TOKEN` (header `Authorization: Bearer`) |
| API key | `ANTHROPIC_API_KEY` (header `x-api-key`) |
| Model chính | `ANTHROPIC_MODEL` |
| opus / sonnet / haiku | `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_` / `_HAIKU_` |
| Tách riêng cấu hình | `CLAUDE_CONFIG_DIR` |

Nếu gọi API trả về lỗi 401, hãy đổi kiểu xác thực. Mỗi nhà cung cấp đọc key ở một header khác nhau.

## Cấu trúc thư mục

```
~/.claude-profiles/
  profiles.json        danh sách profile + cài đặt (không chứa key)
  bin/claude-<tên>     lệnh chạy cho từng profile
  homes/<tên>/         cấu hình Claude riêng của profile (session, settings, history)
```

Tùy chọn **Dùng chung từ ~/.claude** tạo symlink cho `CLAUDE.md`, `skills`, `commands`, `agents`, `output-styles` vào thư mục của profile. `settings.json` và thông tin đăng nhập vẫn riêng cho từng profile.

Khi xóa profile, app chỉ xóa lệnh và key. Thư mục `homes/<tên>` được giữ lại để không mất lịch sử session.

## Mã nguồn

- `src/main.rs`: giao diện
- `src/store.rs`: profile, sinh lệnh chạy, mở terminal
- `src/secret.rs`: Keychain
