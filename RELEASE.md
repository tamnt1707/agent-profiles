# Releasing Agent Profiles / Phát hành Agent Profiles

English | [Tiếng Việt](#tiếng-việt)

The app updates itself: it looks at the releases of the repository, checks the
signature of the archive and replaces the installed `.app`. This document
describes how a release is made.

## 1. The files that matter

| File | What it is |
| --- | --- |
| `VERSION` | The version of the next release, for example `0.1.0`. |
| `RELEASE_REPO` | The repository the app checks, `owner/name`. |
| `scripts/release-public-key.txt` | The public key that verifies a release. It is committed. |
| `scripts/release-keygen.swift` | Creates the key pair. |
| `scripts/release-sign.swift` | Signs the archive of a release. |
| `scripts/release.sh` | Prepares a release. |

`build-mac.sh` reads `VERSION` for `CFBundleShortVersionString` and
`CFBundleVersion`, and writes `UpdateRepo` (from `RELEASE_REPO`, the
environment variable `UPDATE_REPO` wins) and `UpdatePublicKey` (from
`scripts/release-public-key.txt`) into the `Info.plist` of the app. The app
reads both keys from there.

## 2. The key pair

The private key signs the archive of a release, the public key is built into
the app and checks the signature. A release whose signature does not match is
refused: there is no way to install it anyway.

Create the key pair once:

```sh
swift scripts/release-keygen.swift
```

The script writes the private key to `~/.claude-profiles/release-ed25519.key`
with the rights `0600` and prints the public key:

```
private key: /Users/tamnt/.claude-profiles/release-ed25519.key
public key:  3EtY7l2/db66V3d8JqjJP4TYIDyQ9ANbPgql6FydNaU=
```

- Put the **public key** into `scripts/release-public-key.txt` and commit it.
- Keep the **private key** out of the repository. It never enters a commit and
  it is not in the build folder. Copy it somewhere safe: without it no new
  release can be signed, and with it everybody can publish an update.
- The key of the app that is already installed has to stay the same, otherwise
  the app refuses its own updates.

## 3. Making a release

```sh
export RELEASE_KEY_FILE="$HOME/.claude-profiles/release-ed25519.key"
scripts/release.sh
```

The script

1. reads `VERSION` and checks that the git tree is clean and that the tag
   `v<version>` does not exist yet,
2. runs `swift test`,
3. builds the app with `./build-mac.sh --no-install`,
4. packs it into `build/Agent-Profiles-<version>-macos.zip` with
   `ditto -c -k --keepParent`,
5. signs the archive into `build/Agent-Profiles-<version>-macos.zip.sig`,
6. prints the SHA-256 sums of both files,
7. takes the notes from the section of this version in `CHANGELOG.md`,
8. prints the `gh release create` command.

Before a release: raise `VERSION`, and write the notes of that version in
`CHANGELOG.md` as a section `## [<version>] - <date>`. The script refuses to run
without that section and uses it, unchanged, as the notes of the GitHub release
(the app shows these notes when it offers the update).

Nothing is published by default. With

```sh
scripts/release.sh --create-draft
```

the command is run and makes a **draft** release on GitHub. Look at the
assets and the notes, then publish the draft when it is good.

The release needs two assets:

- `Agent-Profiles-<version>-macos.zip`
- `Agent-Profiles-<version>-macos.zip.sig`

A draft and a pre-release are ignored by the app, so a release that is not
ready simply does not show up.

`scripts/release.sh` also rewrites `Casks/agent-profiles.rb` (the Homebrew cask and
`scripts/install.sh` read the same release assets) with the version and the SHA-256 of the
archive. Commit that change to `main` **after** the release is published, with the archive
that was uploaded: a rebuilt archive has another sum and `brew install` would refuse it.

## 4. What the app does with a release

1. `GET https://api.github.com/repos/<RELEASE_REPO>/releases/latest`, without
   a token.
2. The version of the tag is compared with the installed one. A pre-release is
   older than the release itself, so it is only installed when it is really
   newer.
3. The archive is downloaded from `github.com` or `objects.githubusercontent.com`
   over https. Any other host and any redirect to another host is refused, and
   the download is stopped at 200 MB.
4. The signature is checked with the public key of the app over the exact
   bytes of the archive. A missing or wrong signature deletes the downloads and
   stops everything.
5. The archive is unpacked. It has to hold exactly one `Agent Profiles.app`
   with the same bundle identifier, a higher version and the same public key.
   `codesign --verify --deep` has to pass.
6. A helper script waits for the app to quit, moves the old bundle aside,
   puts the new one in place, removes the quarantine, starts the new app and
   cleans up. When a move fails, the old bundle is put back and started again.

## Tiếng Việt

Ứng dụng tự cập nhật: nó xem các bản phát hành của kho lưu trữ, kiểm tra
chữ ký của tệp nén rồi thay thế bản `.app` đang cài. Tài liệu này nói rõ
cách làm một bản phát hành.

## 1. Những file quan trọng

| File | Ý nghĩa |
| --- | --- |
| `VERSION` | Phiên bản của bản phát hành tiếp theo, ví dụ `0.1.0`. |
| `RELEASE_REPO` | Kho lưu trữ mà ứng dụng kiểm tra, `owner/name`. |
| `scripts/release-public-key.txt` | Khoá công khai dùng để xác minh bản phát hành. File này được commit. |
| `scripts/release-keygen.swift` | Tạo cặp khoá. |
| `scripts/release-sign.swift` | Ký tệp nén của bản phát hành. |
| `scripts/release.sh` | Chuẩn bị bản phát hành. |

`build-mac.sh` đọc `VERSION` cho `CFBundleShortVersionString` và
`CFBundleVersion`, rồi ghi `UpdateRepo` (lấy từ `RELEASE_REPO`, biến môi
trường `UPDATE_REPO` được ưu tiên) và `UpdatePublicKey` (lấy từ
`scripts/release-public-key.txt`) vào `Info.plist` của ứng dụng.

## 2. Cặp khoá

Khoá riêng ký tệp nén của bản phát hành, khoá công khai được đóng gói vào
ứng dụng để kiểm tra chữ ký. Bản phát hành có chữ ký không khớp sẽ bị từ
chối: không có cách nào cài nó bằng cách khác.

Tạo cặp khoá một lần:

```sh
swift scripts/release-keygen.swift
```

Khoá riêng được ghi vào `~/.claude-profiles/release-ed25519.key` với quyền
`0600`, khoá công khai được in ra:

```
private key: /Users/tamnt/.claude-profiles/release-ed25519.key
public key:  3EtY7l2/db66V3d8JqjJP4TYIDyQ9ANbPgql6FydNaU=
```

- Đặt **khoá công khai** vào `scripts/release-public-key.txt` và commit nó.
- Giữ **khoá riêng** ngoài kho lưu trữ. Nó không bao giờ được commit và không
  nằm trong thư mục build. Hãy sao lưu ở nơi an toàn: mất nó thì không phát
  hành được bản mới, có nó thì bất kỳ ai cũng có thể đẩy một bản cập nhật.
- Khoá của ứng dụng đã cài phải giữ nguyên, nếu không ứng dụng sẽ từ chối
  chính bản cập nhật của nó.

## 3. Làm một bản phát hành

```sh
export RELEASE_KEY_FILE="$HOME/.claude-profiles/release-ed25519.key"
scripts/release.sh
```

Kịch bản này

1. đọc `VERSION`, kiểm tra cây git sạch và thẻ `v<phiên-bản>` chưa tồn tại,
2. chạy `swift test`,
3. build ứng dụng bằng `./build-mac.sh --no-install`,
4. nén thành `build/Agent-Profiles-<phiên-bản>-macos.zip` bằng
   `ditto -c -k --keepParent`,
5. ký tệp nén thành `build/Agent-Profiles-<phiên-bản>-macos.zip.sig`,
6. in ra giá trị SHA-256 của cả hai tệp,
7. lấy ghi chú từ mục của phiên bản này trong `CHANGELOG.md`,
8. in ra lệnh `gh release create`.

Trước khi phát hành: tăng `VERSION` và viết ghi chú của phiên bản đó trong
`CHANGELOG.md` thành một mục `## [<phiên-bản>] - <ngày>`. Kịch bản từ chối chạy nếu
thiếu mục này và dùng nguyên văn nó làm ghi chú của bản phát hành trên GitHub (app
hiển thị ghi chú này khi đề nghị cập nhật).

Mặc định không có gì được phát hành. Khi chạy

```sh
scripts/release.sh --create-draft
```

lệnh sẽ được chạy và tạo một bản phát hành **nháp** trên GitHub. Hãy xem lại
tệp đính kèm và ghi chú rồi mới công bố bản nháp.

Bản phát hành cần hai tệp đính kèm:

- `Agent-Profiles-<phiên-bản>-macos.zip`
- `Agent-Profiles-<phiên-bản>-macos.zip.sig`

Bản nháp và bản pre-release bị ứng dụng bỏ qua, nên một bản phát hành chưa
xong sẽ không hiện ra.

`scripts/release.sh` cũng ghi lại `Casks/agent-profiles.rb` (cask Homebrew; `scripts/install.sh` dùng
cùng các tệp của bản phát hành) với phiên bản và SHA-256 của tệp zip. Hãy commit thay đổi đó vào `main`
**sau khi** bản phát hành đã được publish, đúng với tệp zip đã tải lên: một tệp zip dựng lại có tổng
khác và `brew install` sẽ từ chối.

## 4. Ứng dụng làm gì với một bản phát hành

1. `GET https://api.github.com/repos/<RELEASE_REPO>/releases/latest`, không
   dùng token.
2. Phiên bản của thẻ được so với phiên bản đang cài. Bản pre-release luôn
   cũ hơn bản chính thức nên chỉ được cài khi nó thật sự mới hơn.
3. Tệp nén được tải từ `github.com` hoặc `objects.githubusercontent.com` qua
   https. Máy chủ khác và mọi chuyển hướng sang máy chủ khác đều bị từ chối,
   và tệp tải xuống bị dừng ở 200 MB.
4. Chữ ký được kiểm tra bằng khoá công khai của ứng dụng trên đúng những byte
   của tệp nén. Chữ ký thiếu hoặc sai sẽ xoá tệp đã tải và dừng mọi thứ.
5. Tệp nén được giải nén. Bên trong phải có đúng một `Agent Profiles.app` với
   cùng bundle identifier, phiên bản cao hơn và cùng khoá công khai.
   `codesign --verify --deep` phải thành công.
6. Một kịch bản trợ giúp chờ ứng dụng thoát, chuyển bản cũ sang bên cạnh,
   đặt bản mới vào chỗ, xoá quarantine, mở ứng dụng mới và dọn dẹp. Nếu
   việc chuyển thất bại, bản cũ được đặt lại và mở lại.
