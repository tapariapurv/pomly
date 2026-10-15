cask "pomly" do
  version "1.0.3"
  sha256 "2f0024a15261f0676044038a4339ca7f43fc86a0d601699a92b9a58421087cc6"

  url "https://github.com/tapariapurv/pomly/releases/download/v#{version}/Pomly-macOS.zip"
  name "Pomly"
  desc "Pomodoro focus timer for the menu bar with drag-to-set and a floating mini timer"
  homepage "https://tapariapurv.github.io/pomly/"

  auto_updates true # Pomly updates itself from GitHub Releases
  depends_on macos: :tahoe

  app "Pomly.app"

  # Not notarized yet: clear the quarantine flag so it opens normally.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Pomly.app"]
  end

  zap trash: [
    "~/Library/Application Scripts/com.purvt.pomly",
    "~/Library/Application Support/Pomly",
    "~/Library/Containers/com.purvt.pomly",
    "~/Library/Preferences/com.purvt.pomly.plist",
    "~/Library/Preferences/group.com.purvt.pomly.plist",
  ]
end
