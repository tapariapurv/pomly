cask "pomly" do
  version "1.0.2"
  sha256 "2f70d4309bcea6c5f07b1056b7d0a36e3bc1597bc4e297f07dbdeba27a965b41"

  url "https://github.com/tapariapurv/pomly/releases/download/v#{version}/Pomly-macOS.zip"
  name "Pomly"
  desc "Pomodoro focus timer for the menu bar with drag-to-set and a floating mini timer"
  homepage "https://tapariapurv.github.io/pomly/"

  depends_on macos: ">= :tahoe"

  app "Pomly.app"

  # Not notarized yet: clear the quarantine flag so it opens normally.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Pomly.app"]
  end

  auto_updates true # Pomly updates itself from GitHub Releases

  zap trash: [
    "~/Library/Preferences/com.purvt.pomly.plist",
    "~/Library/Preferences/group.com.purvt.pomly.plist",
    "~/Library/Application Support/Pomly",
    "~/Library/Containers/com.purvt.pomly",
    "~/Library/Application Scripts/com.purvt.pomly",
  ]
end
