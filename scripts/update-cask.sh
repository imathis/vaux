#!/bin/sh
# Writes Casks/vaux.rb in the Homebrew tap for a release and pushes it.
# Usage: scripts/update-cask.sh <release> <sha256>
set -eu
release=$1
sha=$2
tap=${TAP:-imathis/homebrew-tap}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh repo clone "$tap" "$work" -- --quiet
mkdir -p "$work/Casks"
cat > "$work/Casks/vaux.rb" <<CASK
cask "vaux" do
  version "$release"
  sha256 "$sha"

  url "https://github.com/imathis/vaux/releases/download/v#{version}/Vaux-#{version}.zip"
  name "Vaux"
  desc "Microphone control for the dictation age"
  homepage "https://github.com/imathis/vaux"

  depends_on macos: :tahoe

  app "Vaux.app"

  # Vaux Camera, if it was turned on, goes with Vaux: only Vaux can remove
  # it, and only before the app is deleted.
  uninstall quit:   "dev.imathis.vaux",
            script: {
              executable:   "#{appdir}/Vaux.app/Contents/MacOS/Vaux",
              args:         ["-uninstallCamera"],
              must_succeed: false,
            }

  zap trash: [
    "~/Library/Application Support/dev.imathis.vaux",
    "~/Library/Preferences/dev.imathis.vaux.plist",
  ]
end
CASK
cd "$work"
git add Casks/vaux.rb
if git diff --cached --quiet; then
  echo "Cask already at $release"
else
  git commit --quiet -m "vaux $release"
  git push --quiet
  echo "Cask updated to $release"
fi
