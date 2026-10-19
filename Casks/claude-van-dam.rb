cask "claude-van-dam" do
  version "1.0"
  sha256 "4baad3b98bf0f51796eb0062e43c89df13e501d2739feed1a12ba19cdd58bd0c"

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
