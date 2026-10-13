cask "sparkwatch" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/greatyingzi/sparkwatch/releases/download/v#{version}/SparkWatch-#{version}.dmg"
  name "SparkWatch"
  desc "Menu bar monitor for a DGX Spark fleet and its inference engines"
  homepage "https://github.com/greatyingzi/sparkwatch"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "SparkWatch.app"

  caveats <<~EOS
    SparkWatch is ad-hoc signed rather than notarised, so macOS quarantines it and
    the first launch needs one approval:

      xattr -dr com.apple.quarantine /Applications/SparkWatch.app

    ...or open System Settings > Privacy & Security and allow it there.
    Homebrew 7 removed its no-quarantine flag, so that is the only route.

    Nothing is installed on the machines it monitors: it reads them over SSH, so
    the only requirement there is key-based login (ssh-copy-id you@host).
  EOS

  zap trash: [
    "~/Library/Application Support/SparkWatch",
    "~/Library/LaunchAgents/com.yingzi.sparkwatch.plist",
  ]
end
