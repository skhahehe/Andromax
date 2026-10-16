#!/bin/bash
# Installs Andromax into /Applications and clears the download quarantine,
# so macOS opens it without the "damaged / can't be opened" warning.
set -e
cd "$(dirname "$0")"
echo "Installing Andromax. Enter your Mac password if asked (it won't show as you type)."
sudo rm -rf /Applications/Andromax.app
sudo cp -R Andromax.app /Applications/
sudo xattr -dr com.apple.quarantine /Applications/Andromax.app
echo "Done. Opening Andromax..."
open /Applications/Andromax.app
