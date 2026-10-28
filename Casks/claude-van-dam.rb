cask "claude-van-dam" do
  version "1.1.0"
  sha256 "45dc18437f259db8f9b924f1ab1f674be1a650ebe9b4bf327b7c12dccfc10ec4"

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
