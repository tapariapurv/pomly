cask "pomly" do
  version "1.0.0"
  sha256 "c11487f8f5f261e962be2156b8c19946fcb1f283bd44b815fc29c3eede6866e4"

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

  zap trash: [
    "~/Library/Containers/com.purvt.pomly",
    "~/Library/Application Scripts/com.purvt.pomly",
  ]
end
