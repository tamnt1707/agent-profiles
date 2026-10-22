# Changelog

All notable changes to Claude Profiles are listed here, newest first. The version
is the one in the `VERSION` file. `scripts/release.sh` takes the section of that
version as the notes of the GitHub release.

## [0.2.0] - 2026-10-22

Three new things to see and use: a health dot for every profile, a menu bar launcher and token usage
per profile. All the new settings are optional, and a `profiles.json` from 0.1.0 opens unchanged.

### English

**New**
- **Health dots.** Every profile in the sidebar has a dot: ready, not tested, needs attention or a problem. Each state
  has its own shape as well as its color, and a tooltip gives the reason. *Check all connections* tests the profiles one
  at a time, only after you confirm (it sends one tiny request to each provider, about one token), shows its
  progress and can be stopped. Nothing is ever sent in the background.
- **Menu bar launcher.** Open any profile in one click from the menu bar, in its own folder. *Open in a folder…* lists
  your profiles with their five most recent folders and lets you pick another one. A profile without a key is
  shown dimmed. Turn it off in Settings > General (it is on by default).
- **Token usage per profile.** A new *Usage* section (collapsed until you open it) shows Today, the last 7 days and
  all time, with input, output and cache tokens, counted from the profile's own session history on your Mac.
  Nothing leaves your computer and no conversation text is kept. You can enter a price per million tokens to see an
  upper estimate of the cost. Counting can be stopped, and big histories are read quickly.

**Safer**
- A connection check can never send a key to the address of another profile, even if you save a profile while a
  check is running.
- A folder whose name contains a control character (a tab, a line break…) is refused for *Open in terminal*, the
  menu bar and the working directory, because a terminal could act on it.
- If the Keychain cannot be read, the profile shows "Could not read the Keychain" instead of a false "no key".
- The updater's helper script now uses the system tools by their full path, so nothing on your PATH can change how
  an update is installed.

**Good to know**
- `profiles.json` gains optional fields (`recent_dirs`, `show_menu_bar` and the two price fields). If you go back to
  0.1.0, it ignores them and removes them the next time it saves.

### Tiếng Việt

**Mới**
- **Chấm trạng thái.** Mỗi profile ở cột bên có một chấm: sẵn sàng, chưa kiểm tra, cần chú ý hoặc có lỗi. Mỗi trạng thái có
  hình dạng riêng ngoài màu, và chú thích cho biết lý do. *Kiểm tra tất cả kết nối* thử từng profile một, chỉ sau khi
  bạn xác nhận (gửi một yêu cầu rất nhỏ tới mỗi nhà cung cấp, khoảng một token), có hiển thị tiến độ và dừng được.
  Không có gì được gửi ngầm.
- **Trình khởi chạy trên thanh menu.** Mở bất kỳ profile nào chỉ bằng một cú nhấp từ thanh menu, trong thư mục riêng của
  nó. *Mở trong thư mục…* liệt kê các profile cùng năm thư mục gần nhất và cho bạn chọn thư mục khác. Profile chưa có
  key được làm mờ. Tắt trong Cài đặt > Chung (mặc định đang bật).
- **Thống kê token theo profile.** Mục *Usage* mới (thu gọn cho đến khi bạn mở) cho thấy Hôm nay, 7 ngày gần nhất và
  tất cả, gồm token vào, ra và cache, đếm từ chính lịch sử phiên của profile ngay trên máy bạn. Không có gì rời khỏi
  máy và không lưu nội dung hội thoại. Bạn có thể nhập đơn giá mỗi triệu token để xem ước tính chi phí cận trên. Có thể
  dừng khi đang đếm, và lịch sử lớn được đọc nhanh.

**An toàn hơn**
- Việc kiểm tra kết nối không bao giờ gửi key sang địa chỉ của profile khác, kể cả khi bạn lưu một profile trong lúc đang
  kiểm tra.
- Thư mục có tên chứa ký tự điều khiển (tab, xuống dòng…) bị từ chối khi *Mở trong terminal*, ở thanh menu và ở thư mục
  làm việc, vì terminal có thể thực hiện theo ký tự đó.
- Nếu không đọc được Keychain, profile hiện "Không đọc được Keychain" thay vì báo sai là "chưa có key".
- Script của bộ cập nhật giờ dùng các công cụ hệ thống bằng đường dẫn đầy đủ, nên không gì trong PATH của bạn thay đổi
  được cách cài một bản cập nhật.

**Cần biết**
- `profiles.json` có thêm các trường tùy chọn (`recent_dirs`, `show_menu_bar` và hai trường giá). Nếu quay lại 0.1.0, nó bỏ qua
  các trường này và xóa chúng ở lần lưu kế tiếp.

## [0.1.0] - 2026-10-22

First release. Claude Profiles is now a native macOS app written in Swift and
SwiftUI. It replaces the earlier Rust and egui prototype.

### English

**Requirements:** macOS 14 or later, Apple Silicon (arm64) Mac. The app is signed
ad hoc and not notarized: the first time, right-click the app and choose Open.

**Profiles**
- Manage as many provider profiles for Claude Code as you like. Each has a Base URL,
  an authentication type (Bearer token, API key or none), a main model, the
  opus / sonnet / haiku model mapping, extra environment variables and an optional
  working directory.
- Provider templates fill the Base URL and authentication for OpenRouter, DeepSeek,
  Kimi (Moonshot), GLM (Z.ai), MiniMax and a local proxy.
- Every profile gets a command `claude-<name>`. The name follows the profile name by
  default and can be edited. A name that another profile already uses, or a file in
  the `bin` folder that the app did not create, is an error and is never overwritten.
- Each profile can have its own Claude configuration folder (`CLAUDE_CONFIG_DIR`), so
  your own `~/.claude` and the Claude Desktop app are never touched. `CLAUDE.md`,
  `skills`, `commands`, `agents` and `output-styles` can be shared from `~/.claude`.
- Your edits are never lost by accident: switching profile or starting a new one with
  unsaved changes asks to save, discard or cancel.

**Keys and safety**
- API keys live only in the macOS Keychain. They are never written to a file, to the
  launcher script, to a log or to an error message. The launcher reads the key when
  it runs and says whether the key is missing or the Keychain is locked.
- Launcher scripts are safe against hostile names, URLs and environment values.
- `profiles.json` is written atomically. A file that cannot be read is copied aside,
  your settings are kept, nothing is overwritten until a copy exists, and a banner
  offers Reload and Show backup.
- Deleting a profile removes everything that belongs to it: the key in the Keychain,
  the command, and the configuration folder with its sessions. Symbolic links to
  `~/.claude` are removed as links and are never followed.

**Terminal**
- Open in terminal (Terminal or iTerm2) runs the profile in a new window, in its
  working directory.
- Copy command copies `claude-<name>`.
- Terminal commands setup puts the `claude-<name>` commands on the PATH of zsh, bash,
  fish and sh with one managed block (a dedicated file for fish). It asks first, keeps
  a backup, never edits a line you wrote, restores your files exactly when removed, and
  copies the `source` command for terminals that are already open. Other shells get the
  line to add by hand. Removing the last profile offers to remove the setup.

**Connection**
- Test connection sends a tiny real request (about one token) the way Claude Code
  would and tells you what is wrong: key, authentication type, Base URL, model name,
  rate limit, network. The key goes only to your Base URL, never over plain HTTP to a
  remote host, and never follows a redirect to another host.
- The model field is a combo box: type any name or pick from the models the provider
  lists. The list is loaded only when you open it.

**App**
- English and Vietnamese, switchable at run time. Light, dark or system theme.
- A generated app icon, and a `.dmg` installer for the first install.
- Updates: Check for Updates (menu and Settings) looks at GitHub Releases, downloads
  the new version, verifies its Ed25519 signature, replaces the app and reopens it.
  A bad or missing signature is never installed.

### Tiếng Việt

**Yêu cầu:** macOS 14 trở lên, máy Mac Apple Silicon (arm64). App được ký ad hoc và
chưa notarize: lần đầu hãy bấm chuột phải vào app rồi chọn Mở.

**Profile**
- Quản lý bao nhiêu profile nhà cung cấp cho Claude Code cũng được. Mỗi profile có Base
  URL, kiểu xác thực (Bearer token, API key hoặc không cần), model chính, ánh xạ model
  opus / sonnet / haiku, biến môi trường thêm và thư mục làm việc tùy chọn.
- Có mẫu nhà cung cấp tự điền Base URL và xác thực cho OpenRouter, DeepSeek, Kimi
  (Moonshot), GLM (Z.ai), MiniMax và proxy nội bộ.
- Mỗi profile có lệnh `claude-<tên>`. Tên mặc định theo tên profile và sửa được. Tên
  trùng với profile khác, hoặc file trong thư mục `bin` không phải do app tạo, sẽ báo
  lỗi và không bao giờ bị ghi đè.
- Mỗi profile có thể có thư mục cấu hình Claude riêng (`CLAUDE_CONFIG_DIR`), nên
  `~/.claude` của bạn và app Claude Desktop không bị đụng tới. Có thể dùng chung
  `CLAUDE.md`, `skills`, `commands`, `agents`, `output-styles` từ `~/.claude`.
- Không mất chỉnh sửa vì sơ ý: chuyển profile hoặc thêm mới khi có thay đổi chưa lưu
  thì app hỏi Lưu, Hủy bỏ hay Hủy.

**Key và an toàn**
- API key chỉ nằm trong Keychain của macOS. Key không bao giờ được ghi ra file, vào
  script, log hay thông báo lỗi. Script đọc key lúc chạy và báo rõ là thiếu key hay
  Keychain đang khóa.
- Script khởi chạy an toàn với tên, URL và biến môi trường độc hại.
- `profiles.json` được ghi nguyên tử. File không đọc được sẽ được sao lưu, cài đặt của
  bạn được giữ, không ghi đè khi chưa có bản sao, và banner có nút Tải lại và Hiện bản
  sao lưu.
- Xóa profile là xóa mọi thứ của nó: key trong Keychain, lệnh, thư mục cấu hình cùng
  các phiên. Symlink tới `~/.claude` chỉ bị gỡ như một liên kết, không bao giờ bị đi theo.

**Terminal**
- Mở trong terminal (Terminal hoặc iTerm2) chạy profile trong cửa sổ mới, ở đúng thư
  mục làm việc.
- Copy command chép `claude-<tên>`.
- Thiết lập lệnh trong terminal đưa các lệnh `claude-<tên>` vào PATH của zsh, bash,
  fish và sh bằng một đoạn có đánh dấu (fish dùng file riêng). App hỏi trước, sao lưu,
  không bao giờ sửa dòng bạn tự viết, khôi phục file đúng từng byte khi gỡ, và chép
  sẵn lệnh `source` cho các terminal đang mở. Shell khác thì nhận dòng để tự thêm. Xóa
  profile cuối cùng sẽ hỏi có gỡ thiết lập này không.

**Kết nối**
- Test connection gửi một request thật rất nhỏ (khoảng một token) giống cách Claude Code
  gọi, rồi cho biết lỗi ở đâu: key, kiểu xác thực, Base URL, tên model, giới hạn tốc độ
  hay mạng. Key chỉ gửi đến Base URL của bạn, không gửi qua HTTP thường tới host ngoài,
  và không theo chuyển hướng sang host khác.
- Ô model là combo box: gõ tên tùy ý hoặc chọn từ danh sách model của nhà cung cấp.
  Danh sách chỉ được tải khi bạn mở nó.

**Ứng dụng**
- Tiếng Anh và tiếng Việt, đổi ngay khi đang chạy. Giao diện sáng, tối hoặc theo hệ
  thống.
- Có icon tự tạo và bộ cài `.dmg` cho lần cài đầu.
- Cập nhật: Kiểm tra cập nhật (trong menu và Cài đặt) xem GitHub Releases, tải bản mới,
  kiểm tra chữ ký Ed25519, thay app và mở lại. Chữ ký sai hoặc thiếu thì không bao giờ
  được cài.
