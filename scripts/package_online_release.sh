#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
installed_app="$HOME/Library/Input Methods/BiLing.app"
version=$(plutil -extract CFBundleShortVersionString raw \
  "$project_root/Resources/App/Info.plist")
archive_name="BiLing-$version-online-installer-macOS-arm64.zip"
model_name="qwen3-0.6b-base-q4_k_m.gguf"
dist_dir="$project_root/dist"

if [[ ! -d "$installed_app" ]]; then
  print -u2 "The installed release app is missing: $installed_app"
  exit 66
fi
codesign --verify --deep --strict "$installed_app"

staging_root=$(mktemp -d)
trap 'rm -rf "$staging_root"' EXIT
package_root="$staging_root/BiLing-$version"
mkdir -p "$package_root/LaunchAgents"
ditto "$installed_app" "$package_root/BiLing.app"
model_path="$package_root/BiLing.app/Contents/Resources/Models/$model_name"
if [[ ! -f "$model_path" ]]; then
  print -u2 "The source app does not contain the release model."
  exit 78
fi
rm -f "$model_path"

ditto "$project_root/Resources/LaunchAgents/com.biling.inputmethod.engine.plist.in" \
  "$package_root/LaunchAgents/com.biling.inputmethod.engine.plist.in"
ditto "$project_root/Resources/LaunchAgents/com.biling.inputmethod.app.plist.in" \
  "$package_root/LaunchAgents/com.biling.inputmethod.app.plist.in"
ditto "$project_root/scripts/install_online.sh" "$package_root/在线安装笔灵.command"
ditto "$project_root/scripts/install_prebuilt.sh" "$package_root/安装笔灵.command"
ditto "$project_root/scripts/uninstall.sh" "$package_root/卸载笔灵.command"
ditto "$project_root/Docs/INSTALL_RELEASE.txt" "$package_root/请先阅读.txt"
chmod +x "$package_root/"*.command

mkdir -p "$dist_dir"
archive_path="$dist_dir/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$package_root" "$archive_path"
shasum -a 256 "$archive_path"
print "$archive_path"
