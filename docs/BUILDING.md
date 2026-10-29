# Building Agent Profiles / Tự build Agent Profiles

## English

You need a Mac with macOS 14 or later and the Xcode Command Line Tools (Swift 6.2). The first build
downloads the one dependency, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (the terminal inside
the app), at the exact version pinned in `Package.resolved`, so it needs the network once.

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

The code is split in two: `Sources/AgentProfilesCore` holds the logic and is covered by the
tests, and `Sources/AgentProfiles` holds the SwiftUI interface.

## Tiếng Việt

Bạn cần một máy Mac chạy macOS 14 trở lên và Xcode Command Line Tools (Swift 6.2). Lần build đầu tải về dependency
duy nhất, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (terminal trong ứng dụng), đúng phiên bản được ghim
trong `Package.resolved`, nên cần mạng một lần.

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

Mã nguồn chia làm hai: `Sources/AgentProfilesCore` chứa logic và được test phủ, còn
`Sources/AgentProfiles` chứa giao diện SwiftUI.
