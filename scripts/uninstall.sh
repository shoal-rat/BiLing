#!/bin/zsh
set -euo pipefail

labels=(
  "com.biling.inputmethod.app"
  "com.biling.inputmethod.engine"
)
installed_app="$HOME/Library/Input Methods/BiLing.app"
trash_dir="$HOME/.Trash"
timestamp=$(date +%Y%m%d-%H%M%S)

for label in "${labels[@]}"; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
done
killall BiLingApp 2>/dev/null || true

if [[ -e "$installed_app" ]]; then
  mv "$installed_app" "$trash_dir/BiLing-$timestamp.app"
  print "Moved BiLing.app to Trash."
fi
for label in "${labels[@]}"; do
  launch_plist="$HOME/Library/LaunchAgents/$label.plist"
  if [[ -e "$launch_plist" ]]; then
    mv "$launch_plist" "$trash_dir/$label-$timestamp.plist"
    print "Moved $label LaunchAgent to Trash."
  fi
done
killall TextInputMenuAgent 2>/dev/null || true
print "Personal learning data remains in ~/Library/Application Support/BiLing."
