cask "claude-van-dam" do
  version "1.1.1"
  sha256 "c047c04e2081414e035887d6cf82ffa08633f92fc507d363b06e66538a0bf65f"

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
