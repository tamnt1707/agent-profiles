cask "agent-profiles" do
  version "0.6.0"
  sha256 "8c29a89c6854faa9336686853bf01b75bdf3d16cd15e0d8dd45f7b48238d82d8"

  url "https://github.com/tamnt1707/agent-profiles/releases/download/v#{version}/Agent-Profiles-#{version}-macos.zip"
  name "Agent Profiles"
  desc "Run Claude Code through per-profile provider settings"
  homepage "https://github.com/tamnt1707/agent-profiles"

  # The app checks the releases and updates itself.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Agent Profiles.app"

  # The app is not notarized by Apple, so the quarantine flag would make macOS refuse it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Agent Profiles.app"]
  end
end
