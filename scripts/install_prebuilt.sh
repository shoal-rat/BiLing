#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
if [[ -d "$script_dir/BiLing.app" ]]; then
  release_root="$script_dir"
else
  release_root=${script_dir:h}
fi
release_app="$release_root/BiLing.app"
templates_dir="$release_root/LaunchAgents"
engine_label="com.biling.inputmethod.engine"
app_label="com.biling.inputmethod.app"
model_name="qwen3-0.6b-base-q4_k_m.gguf"
expected_sha256="218d3f063193b40008d4e63d90cf83e7dc6d33a8c6c1c647589f868a8fc74492"

if [[ ! -d "$release_app" ]]; then
  print -u2 "BiLing.app is missing beside this installer."
  exit 66
fi
for template in "$templates_dir/$engine_label.plist.in" "$templates_dir/$app_label.plist.in"; do
  if [[ ! -f "$template" ]]; then
    print -u2 "Release metadata is missing: $template"
    exit 66
  fi
done

staging_root=$(mktemp -d)
trap 'rm -rf "$staging_root"' EXIT
source_app="$staging_root/BiLing.app"
ditto "$release_app" "$source_app"

# Cloud-synced folders may attach Finder/File Provider metadata to extracted
# bundle directories. Those attributes are not executable content, but strict
# code-signature validation rejects them. Preserve quarantine and provenance.
find "$source_app" -type d -exec \
  xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
find "$source_app" -type d -exec \
  xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
codesign --verify --deep --strict "$source_app"
source_binary="$source_app/Contents/MacOS/BiLingApp"
source_model="$source_app/Contents/Resources/Models/$model_name"
actual_sha256=$(shasum -a 256 "$source_model" | awk '{print $1}')
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  print -u2 "The bundled Qwen model failed its SHA-256 integrity check."
  exit 78
fi
original_input_source=$("$source_binary" --current-input-source 2>/dev/null || true)

uid=$(id -u)
launch_agents_dir="$HOME/Library/LaunchAgents"
application_support_dir="$HOME/Library/Application Support/BiLing"
destination="$HOME/Library/Input Methods/BiLing.app"
backup_dir="$application_support_dir/Backups"
mkdir -p "$launch_agents_dir" "$application_support_dir" "${destination:h}"

launchctl bootout "gui/$uid/$app_label" 2>/dev/null || true
launchctl bootout "gui/$uid/$engine_label" 2>/dev/null || true
killall BiLingApp 2>/dev/null || true

if [[ -e "$destination" ]]; then
  mkdir -p "$backup_dir"
  backup="$backup_dir/BiLing.previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$backup"
  print "Previous installation preserved at $backup"
fi
ditto "$source_app" "$destination"

engine_plist="$launch_agents_dir/$engine_label.plist"
sed \
  -e "s|__ENGINE_PATH__|$destination/Contents/Helpers/biling-engined|g" \
  -e "s|__MODEL_PATH__|$destination/Contents/Resources/Models/$model_name|g" \
  -e "s|__BACKEND_PATH__|$destination/Contents/Backends|g" \
  -e "s|__LOG_PATH__|$application_support_dir/engine.log|g" \
  "$templates_dir/$engine_label.plist.in" > "$engine_plist"
plutil -lint "$engine_plist"
launchctl enable "gui/$uid/$engine_label"
launchctl bootstrap "gui/$uid" "$engine_plist"
launchctl kickstart -k "gui/$uid/$engine_label"

xpc_smoke_log="$staging_root/qwen-xpc-smoke.log"
if ! /usr/bin/perl -e 'alarm 45; exec @ARGV' \
  "$destination/Contents/Helpers/biling-cli" \
  --xpc jilindaxuelajixuexiao >"$xpc_smoke_log" 2>&1 \
  || ! grep -q '^1\. 吉林大学垃圾学校' "$xpc_smoke_log"; then
    print -u2 "The installed Qwen service failed its release check:"
    tail -n 80 "$xpc_smoke_log" >&2
    exit 70
fi
"$destination/Contents/MacOS/BiLingApp" --engine-status-test
"$destination/Contents/MacOS/BiLingApp" --register-input-source
killall TextInputMenuAgent 2>/dev/null || true
if [[ -n "$original_input_source" ]]; then
  "$destination/Contents/MacOS/BiLingApp" \
    --select-input-source "$original_input_source" 2>/dev/null || true
fi

app_plist="$launch_agents_dir/$app_label.plist"
sed \
  -e "s|__APP_PATH__|$destination/Contents/MacOS/BiLingApp|g" \
  -e "s|__LOG_PATH__|$application_support_dir/app.log|g" \
  "$templates_dir/$app_label.plist.in" > "$app_plist"
plutil -lint "$app_plist"
launchctl enable "gui/$uid/$app_label"
launchctl bootstrap "gui/$uid" "$app_plist"
launchctl kickstart -k "gui/$uid/$app_label"

print ""
print "笔灵 1.2.0 已安装，输入法与 Qwen 会在登录时自动启动。"
print "请从菜单栏输入法菜单选择“笔灵”后开始输入。"
