#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
installed_app="$HOME/Library/Input Methods/BiLing.app"
version=$(plutil -extract CFBundleShortVersionString raw \
  "$project_root/Resources/App/Info.plist")
bundle_version=$(plutil -extract CFBundleVersion raw \
  "$project_root/Resources/App/Info.plist")
archive_name="BiLing-$version-macOS-arm64.zip"
dist_dir="$project_root/dist"

if [[ ! -d "$installed_app" ]]; then
  print -u2 "The installed release app is missing: $installed_app"
  exit 66
fi
installed_version=$(plutil -extract CFBundleShortVersionString raw \
  "$installed_app/Contents/Info.plist")
installed_build=$(plutil -extract CFBundleVersion raw \
  "$installed_app/Contents/Info.plist")
if [[ "$installed_version" != "$version" || "$installed_build" != "$bundle_version" ]]; then
  print -u2 "Installed app is $installed_version ($installed_build), expected $version ($bundle_version)."
  exit 65
fi
codesign --verify --deep --strict "$installed_app"

staging_root=$(mktemp -d)
trap 'rm -rf "$staging_root"' EXIT
package_root="$staging_root/BiLing-$version"
mkdir -p "$package_root/LaunchAgents"
ditto "$installed_app" "$package_root/BiLing.app"
find "$package_root/BiLing.app" -type d -exec \
  xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
find "$package_root/BiLing.app" -type d -exec \
  xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
codesign --verify --deep --strict "$package_root/BiLing.app"
ditto "$project_root/Resources/LaunchAgents/com.biling.inputmethod.engine.plist.in" \
  "$package_root/LaunchAgents/com.biling.inputmethod.engine.plist.in"
ditto "$project_root/Resources/LaunchAgents/com.biling.inputmethod.app.plist.in" \
  "$package_root/LaunchAgents/com.biling.inputmethod.app.plist.in"
ditto "$project_root/scripts/install_prebuilt.sh" "$package_root/安装笔灵.command"
ditto "$project_root/scripts/uninstall.sh" "$package_root/卸载笔灵.command"
ditto "$project_root/Docs/INSTALL_RELEASE.txt" "$package_root/请先阅读.txt"
chmod +x "$package_root/安装笔灵.command" "$package_root/卸载笔灵.command"

mkdir -p "$dist_dir"
archive_path="$dist_dir/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$package_root" "$archive_path"
shasum -a 256 "$archive_path"
print "$archive_path"
