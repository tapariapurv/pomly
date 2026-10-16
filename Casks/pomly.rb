cask "pomly" do
  version "1.1.0"
  sha256 "77d85651ff109a8203b60d87863c6cdf188498ba6ec9afd71d2d2df9ada127a8"

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
