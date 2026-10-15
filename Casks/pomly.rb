cask "pomly" do
  version "1.0.1"
  sha256 "a08cb739c663e8c05fdc8c52d2ebed36046695f59e6afd3871ba3d0576aa105b"

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
