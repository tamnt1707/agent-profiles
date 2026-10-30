cask "agent-profiles" do
  version "0.6.1"
  sha256 "56f09c1cde75c8bc7af94a42c35c039f118ba23a6406eace83c1ddbebea6b8bc"

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
