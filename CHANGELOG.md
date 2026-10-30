# Changelog

All notable changes to Claude Profiles are listed here, newest first. The version
is the one in the `VERSION` file. `scripts/release.sh` takes the section of that
version as the notes of the GitHub release.

## [0.6.0] - 2026-10-30

A queue workflow for the orchestration kit, diagrams of both workflows, and a choice of how a terminal starts.

### English

**New**
- **Queue workflow.** The *Orchestration* tab has a second workflow next to *Sequential*. Coders merge into the task
  branch as soon as lint and format pass, a `secretary` agent writes one numbered file per merge into
  `.orchestra/queue/`, and the tester follows the queue in order and runs the whole suite when no more code is coming.
  A bug becomes a new queue entry for backend or frontend. The task branch goes into a higher branch only when
  everything is green. It never touches `main` or `master`.
- **New agents.** `frontend-2d` (Sonnet) and `frontend-3d` (Opus, medium effort) replace the single frontend agent of
  the queue workflow: easy tasks go to 2D, 3D work also covers 2D, and never both on one task. Also `backend`,
  `secretary` and a tester that follows the queue. `builder` stays for other work.
- **Diagrams.** The *Orchestration* tab draws the chosen workflow as a diagram. It works offline.
- **Update removes retired agents.** The kit keeps a list of names it dropped; installing removes them (with a
  `.bak` backup). Switching from queue to sequential removes the agents only the queue uses, also with a backup.
- **Start mode of a terminal.** The *Terminal* tab no longer starts Claude when you open it. It asks how: *Normal*
  (as before), or *Orchestrator: sequential* / *queue*. An orchestrator session starts Claude with Opus at medium
  effort and the instructions of the workflow, for that session only (nothing is written to `CLAUDE.md`). If the
  agents are not in the profile, the app says so and installs them first. The mode shows next to the name of the tab.
  To use another mode, open a new tab; the earlier conversation stays available with `/resume`.

### Tiếng Việt

**Mới**
- **Quy trình hàng đợi.** Tab *Orchestration* có thêm quy trình thứ hai cạnh *Tuần tự*. Coder merge vào nhánh task
  ngay khi qua lint và format, agent `secretary` ghi mỗi lần merge thành một file có số thứ tự trong
  `.orchestra/queue/`, tester làm theo hàng đợi đúng thứ tự và chạy toàn bộ bộ test khi không còn code mới. Bug thành
  một mục mới trong hàng đợi giao cho backend hoặc frontend. Nhánh task chỉ được merge lên nhánh cao hơn khi mọi thứ
  đều xanh. Quy trình không bao giờ đụng vào `main` hay `master`.
- **Agent mới.** `frontend-2d` (Sonnet) và `frontend-3d` (Opus, effort medium) thay cho một agent frontend của quy
  trình hàng đợi: việc dễ giao 2D, việc 3D đã bao gồm 2D, và không dùng cả hai trên một task. Thêm `backend`,
  `secretary` và tester làm theo hàng đợi. `builder` vẫn dùng cho việc khác.
- **Sơ đồ.** Tab *Orchestration* vẽ quy trình đang chọn thành sơ đồ, chạy được khi không có mạng.
- **Cập nhật gỡ agent cũ.** Kit giữ danh sách tên đã bỏ; khi cài, các agent đó bị gỡ (có bản `.bak`). Chuyển từ
  hàng đợi sang tuần tự cũng gỡ các agent chỉ hàng đợi dùng, cũng có bản sao lưu.
- **Chế độ mở terminal.** Tab *Terminal* không tự chạy Claude khi mở nữa mà hỏi cách mở: *Bình thường* (như cũ),
  hoặc *Điều phối: tuần tự* / *hàng đợi*. Phiên điều phối chạy Claude với Opus effort medium và hướng dẫn của quy
  trình, chỉ cho phiên đó (không ghi gì vào `CLAUDE.md`). Nếu profile chưa có agent, app báo và cài trước. Chế độ
  hiện cạnh tên tab. Muốn dùng chế độ khác, mở tab mới; cuộc hội thoại trước vẫn mở lại được bằng `/resume`.

## [0.5.0] - 2026-10-29

See which account a profile is signed in with.

### English

**New**
- **Account.** The Settings tab of *Default* and of a Claude subscription profile shows the account it is signed in
  with (email, plan and organization), or says that it is not signed in. It is read with `claude auth status`, which
  reads the local sign-in and costs no tokens. The refresh button asks again.

**Fixed**
- macOS asked **Agent Profiles** for access to Photos, Music and volumes. The terminal inside the app started Claude
  Code in your home folder, where it read those folders on the app's behalf. A terminal now starts in an empty
  folder of the app (`~/.claude-profiles/workspace`) and enters the working directory of the profile when it has one,
  and the heartbeat runs in its own folder. Use the working directory of a profile, or a folder from the menu bar, to
  work on a project.
- *Test connection* was missing on a Claude subscription profile. It is there again, below the model fields, and
  tells you when the account is not signed in.

### Tiếng Việt

**Mới**
- **Tài khoản.** Tab Cài đặt của *Mặc định* và của profile Claude subscription hiện tài khoản đang đăng nhập (email,
  gói và tổ chức), hoặc báo là chưa đăng nhập. Thông tin đọc bằng `claude auth status`, chỉ đọc đăng nhập ở máy nên
  không tốn token. Nút làm mới sẽ hỏi lại.

**Đã sửa**
- macOS hỏi quyền truy cập Ảnh, Music và ổ đĩa cho **Agent Profiles**. Terminal trong app khởi chạy Claude Code ở thư
  mục home của bạn, nơi nó đọc các thư mục đó thay cho app. Giờ terminal bắt đầu trong một thư mục rỗng của app
  (`~/.claude-profiles/workspace`) rồi vào thư mục làm việc của profile nếu có, và heartbeat chạy trong thư mục riêng
  của nó. Muốn làm việc trên dự án, hãy đặt thư mục làm việc cho profile hoặc chọn thư mục từ menu bar.
- Nút *Kiểm tra kết nối* bị mất ở profile Claude subscription. Giờ nó có lại, nằm dưới các ô model, và báo khi tài
  khoản chưa đăng nhập.

## [0.4.1] - 2026-10-29

A fix for the connection check of the **Default** Claude Code.

### English

**Fixed**
- *Default* always said "The account is not signed in" although you are signed in. The check now runs plain `claude`
  in your own login shell, with the environment you have and nothing set on top of it, the way you run it in a
  terminal. (The app used to name `~/.claude` in `CLAUDE_CONFIG_DIR`, which makes Claude Code look for the sign-in
  in another place.) Other profiles are checked as before.
- An expired sign-in ("OAuth session expired") is now reported as "not signed in" instead of a generic CLI error.

### Tiếng Việt

**Đã sửa**
- *Mặc định* luôn báo "Tài khoản chưa đăng nhập" dù bạn đã đăng nhập. Giờ phép kiểm tra chạy đúng lệnh `claude` trong
  shell đăng nhập của bạn, với môi trường bạn có và không đặt thêm gì, giống cách bạn chạy trong terminal. (Trước đây
  app ghi `~/.claude` vào `CLAUDE_CONFIG_DIR`, khiến Claude Code tìm đăng nhập ở chỗ khác.) Các profile khác kiểm tra
  như cũ.
- Đăng nhập hết hạn ("OAuth session expired") giờ được báo là "chưa đăng nhập" thay vì lỗi CLI chung chung.

## [0.4.0] - 2026-10-29

A **Heartbeat** that starts your 5 hour usage window at a time you choose, your own **Default** Claude Code in the
sidebar, and Usage and Orchestration as tabs of their own.

### English

**New**
- **Heartbeat.** A schedule per profile that sends one `ping` through its CLI at times of day you choose (clock of
  the Mac, optional weekdays), so the 5 hour usage window of a subscription starts when you want it to: to have the
  window reset at 10:00, start it at 05:00. It is a LaunchAgent, so it runs with the app closed (a Mac that sleeps runs
  it when it wakes up). Each run overwrites one result file (time, exit code, start of the answer) and the Heartbeat
  section shows the last ping, so there is no growing log. *Run now* tries the schedule.
- **Default Claude Code in the sidebar.** The sidebar has two areas: the agents the app created on top, and
  **Default** (your own `~/.claude`) below. Default has a terminal, usage, a connection check with the green/red dot,
  a heartbeat and the Orchestration kit (installing it writes to `~/.claude`, and the tab says so). It cannot be
  deleted, and only its heartbeat schedule is saved in `profiles.json`.
- **Usage and Orchestration are tabs of their own** next to Settings and Terminal, which leaves room for managing
  skills and agents later.

**Changed**
- The *Test connection* button sits below the model fields, because the test needs the model name.
- Deleting a profile removes everything the app added for it: key, launcher, config folder (with the Orchestration
  kit), the heartbeat LaunchAgent and its result, and its entries in the usage cache. The delete dialog lists the
  heartbeat when there is one.

**Fixed**
- The PATH that the app reads from your login shell could contain what your shell prints at start (such as
  "Restored session"). Only the PATH is taken now.

### Tiếng Việt

**Mới**
- **Heartbeat.** Lịch theo từng profile, gửi một `ping` qua CLI của nó vào các giờ bạn chọn (theo giờ của máy, có thể
  chọn ngày trong tuần), để cửa sổ dùng 5 giờ của gói subscription bắt đầu đúng lúc bạn muốn: muốn cửa sổ reset lúc
  10:00 thì cho nó bắt đầu lúc 05:00. Đây là một LaunchAgent nên chạy cả khi app đã đóng (máy đang ngủ thì chạy khi
  thức dậy). Mỗi lần chạy ghi đè một file kết quả (giờ, mã thoát, phần đầu câu trả lời) và mục Heartbeat hiện ping gần
  nhất, nên không có log phình to. *Chạy ngay* để thử lịch.
- **Claude Code mặc định trên sidebar.** Sidebar chia hai vùng: agent do app tạo ở trên, **Mặc định** (`~/.claude` của
  chính bạn) ở dưới. Mặc định có terminal, mức dùng, kiểm tra kết nối với chấm xanh/đỏ, heartbeat và bộ Orchestration
  (cài sẽ ghi vào `~/.claude`, tab có nói rõ). Không xóa được, và chỉ lịch heartbeat của nó được lưu trong
  `profiles.json`.
- **Mức dùng và Orchestration là tab riêng** cạnh Cài đặt và Terminal, để sau này có chỗ quản lý skill và agent.

**Thay đổi**
- Nút *Kiểm tra kết nối* nằm dưới các ô model, vì phép thử cần tên model.
- Xóa một profile gỡ mọi thứ app đã thêm cho nó: key, launcher, thư mục cấu hình (cùng bộ Orchestration), LaunchAgent
  heartbeat và kết quả của nó, và các mục của nó trong cache mức dùng. Hộp thoại xóa liệt kê heartbeat khi có.

**Đã sửa**
- PATH mà app đọc từ shell đăng nhập có thể dính những gì shell in ra lúc khởi động (như "Restored session"). Giờ chỉ
  lấy phần PATH.

## [0.3.0] - 2026-10-29

The app is now **Agent Profiles**, with a terminal inside the window, a choice of CLI, connection checks that go
through the CLI and are remembered, an orchestration kit per profile, and two new provider templates.

### English

**Renamed**
- The app is now **Agent Profiles** (it was Claude Profiles), so the name does not collide with Claude and other
  agents can be added later. Your profiles, keys and the `claude-<name>` commands are unchanged: the data stays in
  `~/.claude-profiles`, the keys stay in the Keychain, and the PATH lines in your shell keep working. The app is now
  `Agent Profiles.app`: remove the old `Claude Profiles.app` once you have moved over. A 0.2.0 app cannot update
  itself to this one, because the archive holds a differently named app: download this version once by hand.

**New**
- **Claude subscription template.** Add a Claude account without an address or a key: the Base URL, the
  authentication and *Test connection* are hidden, the profile gets its own config folder, and Claude Code asks you to
  sign in the first time you open it. *Use another provider instead* brings the fields back. Such a profile is always
  saved with an empty Base URL and no key.
- **Xiaomi MiMo template.**
- **Health dots in the menu bar.** Each profile in the menu bar launcher has the same dot as in the sidebar.
- **Connection checks go through the CLI, and are remembered.** *Test connection*, *Check all connections* and the
  dots now ask the CLI for one short answer (about 1,500 tokens) with the settings of the profile, instead of calling the
  provider directly. That is the request your own command makes, so the model name is used as it is declared (with
  `[1m]`), a Claude subscription can be tested (it says when the account is not signed in), and the answer is the one
  you would get. The result of each profile is kept in `~/.claude-profiles/health-cache.json` (no key, no text of the
  provider) until its settings change or you check it again, so the dots are there as soon as the app opens. When the
  app starts it checks the profiles that have no result yet, once, without asking; turn that off in Settings. This
  replaces the earlier rule that no request was ever sent without a click.
- **Choose the CLI of a profile.** A new profile now has a *CLI* choice that lists the command line agents installed
  on this Mac (found in the usual folders and through your login shell), with where each was found, or a warning and
  *Check again* when it is missing. Only Claude Code is supported for now; other CLIs can be added later. The choice
  is written to `profiles.json` only when it is not Claude Code, so existing files stay as they are.
- **Terminal inside the app.** *Open in terminal* (and the menu bar) now runs the profile in a terminal inside the
  window, with a *Settings | Terminal* switch at the top of each saved profile. Opening the Terminal tab runs the
  profile by itself, in the same `claude-<name>` command that *Copy command* copies. Each profile keeps its own
  session: look at another profile and come back, and the terminal is as you left it. The sidebar marks the profiles
  that run, and quitting asks first when some still do. Each profile can have several tabs: *New session* opens
  another one, *Restart session* starts the current one again and *Close session* closes it (each asks first when a
  process still runs). Turn it off in Settings to use Terminal or iTerm2 as before.
  The terminal is drawn by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
- **Orchestration kit, per profile.** A new *Orchestration* section installs six subagents (scout, researcher, builder,
  tester, reviewer, committer) and the instructions of the orchestrator into the config folder of the profile, with
  *Install*, *Update* and *Remove*. Only that profile changes. The models follow the provider: Haiku and Sonnet for
  Anthropic, the model of the session for a provider without separate models. A profile that shares `agents` or
  `CLAUDE.md` with `~/.claude` through a link is never written through; *Give this profile its own copy* replaces the
  link with a copy (after you confirm) so the kit can go in. `~/.claude` is not changed.
- **Delete in the sidebar menu.** Right-click a profile and choose *Delete*: the same question as the button asks first.

**Fixed**
- Deleting a profile while Claude Code still runs in a terminal of that profile could leave its config folder behind,
  because the folder was written to while it was emptied. The removal now repeats a few times.
- The health dots in the sidebar stayed grey after a check until the next minute. They now change as soon as the answer
  arrives.
- The result line of *Test connection* showed in white instead of green, orange or red.
- A model name that ends in `[1m]` (the mark of a 1M context in Claude Code) is no longer sent to the provider by the
  connection check, which the provider refused as an unknown model. The saved model and the launcher are unchanged.

### Tiếng Việt

**Đổi tên**
- Ứng dụng giờ tên là **Agent Profiles** (trước là Claude Profiles), để tên không trùng với Claude và sau này thêm được
  các agent khác. Profile, key và các lệnh `claude-<tên>` không đổi: dữ liệu vẫn ở `~/.claude-profiles`, key vẫn trong
  Keychain, và các dòng PATH trong shell vẫn dùng được. Ứng dụng giờ là `Agent Profiles.app`: hãy xóa
  `Claude Profiles.app` cũ sau khi chuyển sang. Bản 0.2.0 không tự cập nhật lên bản này được, vì gói tải về chứa một
  ứng dụng tên khác: hãy tải bản này một lần bằng tay.

**Mới**
- **Template Claude subscription.** Thêm tài khoản Claude mà không cần địa chỉ hay key: Base URL, xác thực và
  *Kiểm tra kết nối* được ẩn, profile có thư mục cấu hình riêng, và Claude Code sẽ yêu cầu đăng nhập ở lần đầu mở.
  *Dùng nhà cung cấp khác* đưa các ô trở lại. Profile kiểu này luôn được lưu với Base URL trống và không có key.
- **Template Xiaomi MiMo.**
- **Kiểm tra kết nối đi qua CLI, và được ghi nhớ.** *Kiểm tra kết nối*, *Kiểm tra tất cả kết nối* và các chấm giờ nhờ
  CLI trả lời một câu ngắn (khoảng 1.500 token) với cài đặt của profile, thay vì gọi thẳng nhà cung cấp. Đó là yêu cầu mà
  lệnh của bạn gửi, nên tên model được dùng đúng như đã khai báo (kể cả `[1m]`), gói đăng ký Claude cũng kiểm tra được
  (báo khi tài khoản chưa đăng nhập), và kết quả là kết quả bạn sẽ nhận. Kết quả của mỗi profile được giữ trong
  `~/.claude-profiles/health-cache.json` (không có key, không có chữ của nhà cung cấp) cho đến khi cài đặt của nó thay
  đổi hoặc bạn kiểm tra lại, nên các chấm có sẵn ngay khi mở ứng dụng. Khi mở, ứng dụng kiểm tra các profile chưa có kết
  quả, một lần, không hỏi; tắt trong Cài đặt. Điều này thay cho quy tắc trước đây là không gửi yêu cầu nào nếu chưa bấm.
- **Chọn CLI cho profile.** Profile mới có mục *CLI* liệt kê các agent dòng lệnh đã cài trên máy này (tìm trong các thư
  mục thường dùng và qua login shell của bạn), kèm nơi tìm thấy, hoặc cảnh báo và nút *Kiểm tra lại* khi chưa cài. Hiện
  chỉ hỗ trợ Claude Code; các CLI khác sẽ thêm sau. Lựa chọn chỉ được ghi vào `profiles.json` khi khác Claude Code, nên
  các file cũ không đổi.
- **Terminal ngay trong ứng dụng.** *Mở trong terminal* (và thanh menu) giờ chạy profile trong một terminal nằm trong
  cửa sổ, với thanh chuyển *Cấu hình | Terminal* ở đầu mỗi profile đã lưu. Mở tab Terminal là profile tự chạy, bằng
  đúng lệnh `claude-<tên>` mà *Sao chép lệnh* sao chép. Mỗi profile giữ phiên riêng: xem profile khác rồi quay lại,
  terminal vẫn như lúc bạn rời đi. Cột bên đánh dấu các profile đang chạy, và thoát ứng dụng sẽ hỏi trước nếu còn
  profile đang chạy. Mỗi profile có thể có nhiều tab: *Phiên mới* mở thêm một tab, *Khởi động lại phiên* chạy lại
  tab đang xem và *Đóng phiên* đóng tab đó (đều hỏi trước nếu tiến trình còn chạy). Tắt trong Cài đặt để dùng Terminal hoặc iTerm2 như trước. Terminal được vẽ bằng
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
- **Bộ Orchestration cho từng profile.** Mục *Orchestration* mới cài sáu subagent (scout, researcher, builder, tester,
  reviewer, committer) và hướng dẫn cho orchestrator vào thư mục cấu hình của profile, với *Cài*, *Cập nhật* và *Gỡ*.
  Chỉ profile đó thay đổi. Model theo nhà cung cấp: Haiku và Sonnet với Anthropic, model của phiên với nhà cung cấp không
  có model riêng từng bậc. Profile dùng chung `agents` hoặc `CLAUDE.md` với `~/.claude` qua liên kết thì không bao giờ bị
  ghi xuyên qua; *Tạo bản sao riêng cho profile này* thay liên kết bằng một bản sao (sau khi bạn xác nhận) để cài được
  bộ kit. `~/.claude` không bị thay đổi.
- **Chấm trạng thái trên thanh menu.** Mỗi profile trong trình khởi chạy trên thanh menu có chấm giống ở cột bên.
- **Xóa trong menu của cột bên.** Nhấp chuột phải vào profile và chọn *Xóa*: hỏi xác nhận giống nút Xóa trong trình chỉnh sửa.

**Đã sửa**
- Xóa profile khi Claude Code vẫn đang chạy trong một terminal của profile đó có thể để sót thư mục cấu hình, vì thư mục
  bị ghi thêm trong lúc đang dọn. Việc xóa giờ được lặp lại vài lần.
- Chấm trạng thái ở cột bên vẫn xám sau khi kiểm tra cho đến phút kế tiếp. Giờ chấm đổi ngay khi có kết quả.
- Dòng kết quả của *Kiểm tra kết nối* hiện màu trắng thay vì xanh, cam hoặc đỏ.
- Tên model kết thúc bằng `[1m]` (dấu hiệu context 1M của Claude Code) không còn được gửi tới nhà cung cấp khi kiểm tra
  kết nối, trước đây bị từ chối là model không tồn tại. Model đã lưu và lệnh khởi chạy không đổi.

## [0.2.0] - 2026-10-22

Three new things to see and use: a health dot for every profile, a menu bar launcher and token usage
per profile. All the new settings are optional, and a `profiles.json` from 0.1.0 opens unchanged.

### English

**New**
- **Health dots.** Every profile in the sidebar has a dot: ready, not tested, needs attention or a problem. Each state
  has its own shape as well as its color, and a tooltip gives the reason. *Check all connections* tests the profiles one
  at a time, only after you confirm (it sends one tiny request to each provider, about one token), shows its
  progress and can be stopped. No request to a provider is ever sent in the background.
- **Menu bar launcher.** Open any profile in one click from the menu bar, in its own folder. *Open in a folder…* lists
  your profiles with their five most recent folders and lets you pick another one. A profile that needs a key and has none is
  disabled, with a "no key" hint. Turn it off in Settings > General (it is on by default).
- **Token usage per profile.** A new *Usage* section (collapsed until you open it) shows Today, the last 7 days and
  all time, with input, output and cache tokens, counted from the profile's own session history on your Mac.
  Nothing leaves your computer and no conversation text is kept. You can enter a price per million tokens to see an
  upper estimate of the cost. Counting can be stopped.

**Safer**
- A connection check can never send a key to the address of another profile, even if you save a profile while a
  check is running.
- A folder whose name contains a control character (a tab, a line break…) is refused for *Open in terminal*, the
  menu bar and the working directory, because a terminal could act on it.
- If the Keychain cannot be read, the profile shows "Could not read the Keychain" instead of a false "no key".
- The updater's helper now starts with an empty environment and calls the system tools by their full path, so a
  tool on your PATH cannot take the place of the real one while an update is installed.

**Good to know**
- `profiles.json` gains optional fields (`recent_dirs`, `show_menu_bar` and the two price fields). If you go back to
  0.1.0, it ignores them and removes them the next time it saves.

### Tiếng Việt

**Mới**
- **Chấm trạng thái.** Mỗi profile ở cột bên có một chấm: sẵn sàng, chưa kiểm tra, cần chú ý hoặc có lỗi. Mỗi trạng thái có
  hình dạng riêng ngoài màu, và chú thích cho biết lý do. *Kiểm tra tất cả kết nối* thử từng profile một, chỉ sau khi
  bạn xác nhận (gửi một yêu cầu rất nhỏ tới mỗi nhà cung cấp, khoảng một token), có hiển thị tiến độ và dừng được.
  Không có yêu cầu nào tới nhà cung cấp được gửi ngầm.
- **Trình khởi chạy trên thanh menu.** Mở bất kỳ profile nào chỉ bằng một cú nhấp từ thanh menu, trong thư mục riêng của
  nó. *Mở trong thư mục…* liệt kê các profile cùng năm thư mục gần nhất và cho bạn chọn thư mục khác. Profile cần key mà
  chưa có thì bị vô hiệu, kèm chữ "no key". Tắt trong Cài đặt > Chung (mặc định đang bật).
- **Thống kê token theo profile.** Mục *Usage* mới (thu gọn cho đến khi bạn mở) cho thấy Hôm nay, 7 ngày gần nhất và
  tất cả, gồm token vào, ra và cache, đếm từ chính lịch sử phiên của profile ngay trên máy bạn. Không có gì rời khỏi
  máy và không lưu nội dung hội thoại. Bạn có thể nhập đơn giá mỗi triệu token để xem ước tính chi phí cận trên. Có thể
  dừng khi đang đếm.

**An toàn hơn**
- Việc kiểm tra kết nối không bao giờ gửi key sang địa chỉ của profile khác, kể cả khi bạn lưu một profile trong lúc đang
  kiểm tra.
- Thư mục có tên chứa ký tự điều khiển (tab, xuống dòng…) bị từ chối khi *Mở trong terminal*, ở thanh menu và ở thư mục
  làm việc, vì terminal có thể thực hiện theo ký tự đó.
- Nếu không đọc được Keychain, profile hiện "Không đọc được Keychain" thay vì báo sai là "chưa có key".
- Công cụ phụ của bộ cập nhật giờ khởi động với môi trường trống và gọi các công cụ hệ thống bằng đường dẫn đầy đủ, nên
  một lệnh trong PATH của bạn không thể thay thế lệnh thật khi cài bản cập nhật.

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
