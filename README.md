# Claude Profiles

App desktop (Swift + SwiftUI) để quản lý nhiều profile nhà cung cấp cho Claude Code trên macOS.

- Mỗi profile có Base URL, model và API key riêng.
- API key chỉ nằm trong **macOS Keychain**, không ghi ra file.
- Mỗi profile tự sinh một lệnh `claude-<tên>` thay cho các file batch viết tay.
- Mỗi profile có thư mục cấu hình Claude riêng (`CLAUDE_CONFIG_DIR`), nên **`~/.claude` gốc và app Claude Desktop không bị đụng tới**.
- Giao diện là SwiftUI thuần, có thể đổi **ngôn ngữ** (English / Tiếng Việt) và **giao diện sáng/tối** ngay trong app.

## Tiếng Việt

### Build và cài

Cần Swift 6.2 (Xcode Command Line Tools) và macOS 14 trở lên.

```bash
cd claude-profiles
./build-mac.sh
```

Script build bản release bằng SwiftPM, tạo `~/Applications/Claude Profiles.app`, ký ad-hoc và kiểm tra là bản dịch nằm đúng trong app. Sau đó mở app bằng Spotlight.

Muốn chỉ build mà không cài (app nằm ở `./build`):

```bash
./build-mac.sh --no-install
```

Muốn có file cài đặt `.dmg` (kéo app vào Applications), chạy lệnh dưới đây. File nằm ở `build/Claude-Profiles-<phiên bản>.dmg`. Ảnh đĩa chưa được notarize, nên lần đầu mở có thể cần chuột phải, chọn Mở:

```bash
./build-mac.sh --dmg
```

Để gọi lệnh profile từ mọi terminal, thêm thư mục `bin` vào PATH (chỉ cần làm một lần):

```bash
echo 'export PATH="$HOME/.claude-profiles/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Khi đang phát triển, bạn có thể chạy thẳng bằng `swift run` và chạy test bằng `swift test`.

### Dùng

1. Bấm **Thêm profile** (`Cmd+N`), chọn mẫu nhà cung cấp (hoặc Tùy chỉnh), sau đó điền tên, Base URL, API key và model.
2. Sửa **Tên lệnh** nếu muốn: mặc định phần sau `claude-` bám theo tên profile, gõ tay vào ô thì tên lệnh trở thành của riêng bạn (nút **Đưa về tự động** để quay lại). Trùng tên lệnh với profile khác hoặc trùng với một file lạ trong `bin/` thì app báo lỗi và không cho lưu.
3. Bấm **Lưu** (`Cmd+S`). App sẽ:
   - lưu key vào Keychain (service `claude-profiles`, account = tên lệnh của profile);
   - tạo `~/.claude-profiles/bin/claude-<tên>`;
   - tạo `~/.claude-profiles/homes/<tên>/` làm thư mục cấu hình riêng.
4. Bấm **Mở terminal với profile này** (`Cmd+R`), hoặc gõ `claude-<tên>` trong bất kỳ terminal nào. Mọi tham số đều được chuyển tiếp, ví dụ `claude-glm --resume`.

Lần đầu một lệnh profile đọc key, macOS sẽ hỏi cho phép `security` truy cập Keychain. Chọn **Always Allow** để không bị hỏi lại.

Lần đầu app mở Terminal hoặc iTerm2, macOS sẽ hỏi quyền điều khiển ứng dụng (Automation). Chọn **OK**.

### Ánh xạ biến môi trường

| Trường trong app | Biến môi trường |
|---|---|
| Base URL | `ANTHROPIC_BASE_URL` |
| Bearer token | `ANTHROPIC_AUTH_TOKEN` (header `Authorization: Bearer`) |
| API key | `ANTHROPIC_API_KEY` (header `x-api-key`) |
| Model chính | `ANTHROPIC_MODEL` |
| opus / sonnet / haiku | `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_` / `_HAIKU_` |
| Tách riêng cấu hình | `CLAUDE_CONFIG_DIR` |

Nếu gọi API trả về lỗi 401, hãy đổi kiểu xác thực. Mỗi nhà cung cấp đọc key ở một header khác nhau.

Ngoài ra bạn có thể thêm biến riêng, mỗi dòng một biến `KEY=VALUE` (ví dụ `API_TIMEOUT_MS=600000`).

### Cấu trúc thư mục

```
~/.claude-profiles/
  profiles.json        danh sách profile + cài đặt (không chứa key)
  bin/claude-<tên>     lệnh chạy cho từng profile
  homes/<tên>/         cấu hình Claude riêng của profile (session, settings, history)
```

Tùy chọn **Dùng chung từ ~/.claude** tạo symlink cho `CLAUDE.md`, `skills`, `commands`, `agents`, `output-styles` vào thư mục của profile. `settings.json` và thông tin đăng nhập vẫn riêng cho từng profile.

Khi xóa profile, app xóa hết: mục key trong Keychain, lệnh `claude-<tên>` và toàn bộ thư mục `homes/<tên>` (session, settings, history). Thao tác này không hoàn tác được, nên app hỏi lại trước khi xóa và liệt kê rõ những gì sẽ mất. Các symlink trỏ về `~/.claude` chỉ bị gỡ khỏi thư mục profile, thư mục gốc không bị đụng tới; nếu file nào không xóa được, app báo đường dẫn để bạn tự xóa.

File `profiles.json` giữ nguyên định dạng của app cũ (Rust), nên profile đã tạo vẫn mở được. Nếu file bị hỏng, app copy nó thành `profiles.json.corrupt-<thời gian>` và hiện cảnh báo thay vì xoá mất dữ liệu.

### Mã nguồn

- `Sources/ClaudeProfilesCore/`: lõi không phụ thuộc SwiftUI — `Profile.swift`, `Slug.swift`, `CommandName.swift`, `ShellQuote.swift`, `ScriptRenderer.swift`, `Paths.swift`, `Store.swift`, `SafeFileSystem.swift`, `ProfileError.swift`, `Keychain.swift`, `Launcher.swift`.
- `Sources/ClaudeProfiles/`: app SwiftUI — `ClaudeProfilesApp.swift`, `AppModel.swift`, `ContentView.swift`, `ProfileEditorView.swift`, `SettingsView.swift`, `Localization.swift` và `Resources/` (chuỗi `en.lproj`, `vi.lproj`, icon).
- `Tests/ClaudeProfilesCoreTests/`: test của lõi, kèm file golden của định dạng app cũ (Rust) và của lệnh chạy hiện tại.
- `scripts/make-icon.swift`: vẽ biểu tượng app.
- `build-mac.sh`: build và đóng gói `Claude Profiles.app`.

### Ngôn ngữ, giao diện và biểu tượng

- **Ngôn ngữ**: trong Cài đặt (`Cmd+,`) chọn Hệ thống / English / Tiếng Việt. Đổi xong app hiện lại ngay, và tất cả lệnh `claude-<tên>` được viết lại cho khớp ngôn ngữ.
- **Giao diện**: Hệ thống / Sáng / Tối, áp dụng cho cả cửa sổ lẫn hộp thoại.
- **Biểu tượng**: `scripts/make-icon.swift` vẽ bằng CoreGraphics rồi chạy `iconutil`; `Sources/ClaudeProfiles/Resources/AppIcon.icns` đã được commit nên build không cần chạy script.

## English

A macOS desktop app (Swift + SwiftUI) that manages several provider profiles for Claude Code.

- Every profile has its own base URL, model and API key.
- The API key only lives in the **macOS Keychain**, never in a file.
- Every profile creates a `claude-<name>` command, so no hand written launcher files are needed.
- Every profile gets its own Claude configuration folder (`CLAUDE_CONFIG_DIR`), so **the original `~/.claude` and the Claude Desktop app are never touched**.
- The interface is plain SwiftUI and can switch between **English** and **Tiếng Việt** and between the **light and dark** appearance while it runs.

### Build and install

You need Swift 6.2 (Xcode Command Line Tools) and macOS 14 or newer.

```bash
cd claude-profiles
./build-mac.sh
```

The script builds the release with SwiftPM, creates `~/Applications/Claude Profiles.app`, signs it ad-hoc and checks that the localized strings really load from the assembled app. Open it from Spotlight afterwards.

To build without installing (the app ends up in `./build`):

```bash
./build-mac.sh --no-install
```

To get a `.dmg` installer (drag the app into Applications), run the command below. The file is `build/Claude-Profiles-<version>.dmg`. The image is not notarized, so the first time you may need to right-click and choose Open:

```bash
./build-mac.sh --dmg
```

To call a profile command from every terminal, add the `bin` folder to your PATH (once):

```bash
echo 'export PATH="$HOME/.claude-profiles/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

While developing you can run `swift run` directly and `swift test` for the test suite.

### Usage

1. Press **Add profile** (`Cmd+N`), pick a provider template (or Custom) and fill in the name, the base URL, the API key and the model.
2. Edit **Command name** if you want: by default the part after `claude-` follows the profile name; type into the field and the command becomes one of your own (the button **Reset to auto** brings it back). A command that another profile already uses, or that belongs to a foreign file in `bin/`, is an error and cannot be saved.
3. Press **Save** (`Cmd+S`). The app will:
   - store the key in the Keychain (service `claude-profiles`, account = the command name of the profile);
   - create `~/.claude-profiles/bin/claude-<name>`;
   - create `~/.claude-profiles/homes/<name>/` as the private configuration folder.
4. Press **Open terminal with this profile** (`Cmd+R`), or type `claude-<name>` in any terminal. Every argument is passed on, for example `claude-glm --resume`.

The first time a profile command reads the key, macOS asks for permission to let `security` access the Keychain. Choose **Always Allow** so it does not ask again.

The first time the app opens Terminal or iTerm2, macOS asks for permission to control that application (Automation). Choose **OK**.

### Environment variable mapping

| Field in the app | Environment variable |
|---|---|
| Base URL | `ANTHROPIC_BASE_URL` |
| Bearer token | `ANTHROPIC_AUTH_TOKEN` (`Authorization: Bearer` header) |
| API key | `ANTHROPIC_API_KEY` (`x-api-key` header) |
| Main model | `ANTHROPIC_MODEL` |
| opus / sonnet / haiku | `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_` / `_HAIKU_` |
| Isolated configuration | `CLAUDE_CONFIG_DIR` |

If the API answers with a 401, change the authentication kind: every provider reads the key from a different header.

You can also add your own variables, one `KEY=VALUE` per line (for example `API_TIMEOUT_MS=600000`).

### Folder layout

```
~/.claude-profiles/
  profiles.json        the profile list + the settings (no keys)
  bin/claude-<name>    the command of every profile
  homes/<name>/        the private Claude configuration of the profile (sessions, settings, history)
```

The option **Share from ~/.claude** symlinks `CLAUDE.md`, `skills`, `commands`, `agents` and `output-styles` into the folder of the profile. `settings.json` and the credentials stay private per profile.

When you delete a profile, the app removes everything: the key in the Keychain, the command `claude-<name>` and the whole folder `homes/<name>` (sessions, settings, history). This cannot be undone, so the app asks first and lists exactly what goes away. The symlinks into `~/.claude` are only unlinked from the profile folder, the shared configuration itself is never touched. Whatever cannot be removed is reported with its path, so you can delete it by hand.

`profiles.json` keeps the format of the old Rust app, so existing profiles still open. If the file is broken, the app copies it to `profiles.json.corrupt-<timestamp>` and shows a warning instead of throwing the data away.

### Source map

- `Sources/ClaudeProfilesCore/`: the core, without SwiftUI — `Profile.swift`, `Slug.swift`, `CommandName.swift`, `ShellQuote.swift`, `ScriptRenderer.swift`, `Paths.swift`, `Store.swift`, `SafeFileSystem.swift`, `ProfileError.swift`, `Keychain.swift`, `Launcher.swift`.
- `Sources/ClaudeProfiles/`: the SwiftUI app — `ClaudeProfilesApp.swift`, `AppModel.swift`, `ContentView.swift`, `ProfileEditorView.swift`, `SettingsView.swift`, `Localization.swift` and `Resources/` (the `en.lproj` and `vi.lproj` strings, the icon).
- `Tests/ClaudeProfilesCoreTests/`: the tests of the core, including the golden files of the old app format (Rust) and of the current launcher.
- `scripts/make-icon.swift`: draws the app icon.
- `build-mac.sh`: builds and packages `Claude Profiles.app`.

### Language, appearance and icon

- **Language**: Settings (`Cmd+,`) offers System / English / Tiếng Việt. The app redraws itself immediately and every `claude-<name>` script is rewritten in the new language.
- **Appearance**: System / Light / Dark, applied to the window and to the dialogs.
- **Icon**: `scripts/make-icon.swift` draws it with CoreGraphics and runs `iconutil`; `Sources/ClaudeProfiles/Resources/AppIcon.icns` is committed, so the build never depends on running the script.
