cask "claude-van-dam" do
  version "1.0"
  sha256 "c6f7d7fde2908136a71f69f03acea6e8a4b8908179cabc141a956880d8854f96"

  url "https://github.com/aspasskiy/claude-van-dam/releases/download/v#{version}/Claude-Van-Dam-#{version}.zip"
  name "Claude Van Dam"
  desc "Menu bar app to watch and switch between Claude Code accounts"
  homepage "https://github.com/aspasskiy/claude-van-dam"

  depends_on macos: :sonoma

  app "Claude Van Dam.app"

  uninstall launchctl: "site.spasskiy.claude-van-dam",
            quit:      "site.spasskiy.claude-van-dam",
            delete:    "~/Library/LaunchAgents/site.spasskiy.claude-van-dam.plist"

  zap trash: "~/Library/Preferences/site.spasskiy.claude-van-dam.plist"
end
