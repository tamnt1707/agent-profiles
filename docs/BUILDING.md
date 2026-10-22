# Building Claude Profiles / Tự build Claude Profiles

## English

You need a Mac with macOS 14 or later and the Xcode Command Line Tools (Swift 6.2).

```sh
./build-mac.sh              # build and install into ~/Applications
./build-mac.sh --no-install # build only, into ./build
./build-mac.sh --dmg        # build into ./build and make a .dmg installer
```

Run the tests with:

```sh
swift test
```

Releases are made with `scripts/release.sh`. See [RELEASE.md](../RELEASE.md) for the steps and for
how the signing key is handled, and [CHANGELOG.md](../CHANGELOG.md) for the notes of each version.

The code is split in two: `Sources/ClaudeProfilesCore` holds the logic and is covered by the
tests, and `Sources/ClaudeProfiles` holds the SwiftUI interface.

## Tiếng Việt

Bạn cần một máy Mac chạy macOS 14 trở lên và Xcode Command Line Tools (Swift 6.2).

```sh
./build-mac.sh              # build và cài vào ~/Applications
./build-mac.sh --no-install # chỉ build, vào ./build
./build-mac.sh --dmg        # build vào ./build và tạo bộ cài .dmg
```

Chạy test bằng:

```sh
swift test
```

Bản phát hành được tạo bằng `scripts/release.sh`. Xem [RELEASE.md](../RELEASE.md) để biết các bước và
cách giữ khóa ký, và [CHANGELOG.md](../CHANGELOG.md) để xem ghi chú của từng phiên bản.

Mã nguồn chia làm hai: `Sources/ClaudeProfilesCore` chứa logic và được test phủ, còn
`Sources/ClaudeProfiles` chứa giao diện SwiftUI.
