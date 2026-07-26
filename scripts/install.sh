#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
engine_label="com.biling.inputmethod.engine"
app_label="com.biling.inputmethod.app"
model_name="qwen3-0.6b-base-q4_k_m.gguf"
model_source="$project_root/Models/$model_name"
expected_sha256="218d3f063193b40008d4e63d90cf83e7dc6d33a8c6c1c647589f868a8fc74492"

required_build_dependencies=(
  /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib
  /opt/homebrew/opt/ggml/lib/libggml.0.dylib
  /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib
  /opt/homebrew/opt/libomp/lib/libomp.dylib
)
for dependency in "${required_build_dependencies[@]}"; do
  if [[ ! -f "$dependency" ]]; then
    print -u2 "Missing build dependency: $dependency"
    print -u2 "Install the required packages with: brew install llama.cpp ggml libomp"
    exit 69
  fi
done

if [[ ! -f "$model_source" ]]; then
  print -u2 "Required bundled model is missing: $model_source"
  exit 78
fi

model_size=$(stat -f %z "$model_source")
if (( model_size < 350000000 )); then
  print -u2 "The bundled Qwen model is incomplete ($model_size bytes)."
  exit 78
fi

actual_sha256=$(shasum -a 256 "$model_source" | awk '{print $1}')
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  print -u2 "The bundled Qwen model failed its SHA-256 integrity check."
  print -u2 "Expected: $expected_sha256"
  print -u2 "Actual:   $actual_sha256"
  exit 78
fi

swift build --package-path "$project_root" -c release --product BiLingApp
swift build --package-path "$project_root" -c release --product biling-engined
swift build --package-path "$project_root" -c release --product biling-cli
bin_dir=$(swift build --package-path "$project_root" -c release --show-bin-path)

staging_root=$(mktemp -d)
trap 'rm -rf "$staging_root"' EXIT
bundle="$staging_root/BiLing.app"
contents="$bundle/Contents"
mkdir -p \
  "$contents/MacOS" \
  "$contents/Helpers" \
  "$contents/Frameworks" \
  "$contents/Backends" \
  "$contents/Resources/Models" \
  "$contents/Resources/Licenses"

ditto "$project_root/Resources/App/Info.plist" "$contents/Info.plist"
ditto "$bin_dir/BiLingApp" "$contents/MacOS/BiLingApp"
ditto "$bin_dir/biling-engined" "$contents/Helpers/biling-engined"
ditto "$bin_dir/biling-cli" "$contents/Helpers/biling-cli"
ditto "$project_root/Resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
ditto "$project_root/Resources/AppIcon.png" "$contents/Resources/AppIcon.png"
ditto "$model_source" "$contents/Resources/Models/$model_name"
ditto "$bin_dir/BiLing_BackboneEngine.bundle" "$contents/Resources/BiLing_BackboneEngine.bundle"
ditto "$project_root/Models/LICENSE-QWEN-APACHE-2.0.txt" \
  "$contents/Resources/Licenses/LICENSE-QWEN-APACHE-2.0.txt"
ditto "$project_root/Resources/Lexicon/APACHE-2.0-rime-pinyin-simp.txt" \
  "$contents/Resources/Licenses/APACHE-2.0-rime-pinyin-simp.txt"
ditto "$project_root/Resources/Lexicon/CC-BY-4.0-rime-wanxiang.txt" \
  "$contents/Resources/Licenses/CC-BY-4.0-rime-wanxiang.txt"
ditto "$project_root/Resources/Lexicon/WANXIANG-SOURCE.md" \
  "$contents/Resources/Licenses/WANXIANG-SOURCE.md"
ditto "$project_root/LICENSE" "$contents/Resources/Licenses/LICENSE-BILING-APACHE-2.0.txt"
ditto "$project_root/NOTICE" "$contents/Resources/Licenses/NOTICE-BILING.txt"

ditto /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib "$contents/Frameworks/libllama.0.dylib"
ditto /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$contents/Frameworks/libggml.0.dylib"
ditto /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$contents/Frameworks/libggml-base.0.dylib"
ditto /opt/homebrew/opt/libomp/lib/libomp.dylib "$contents/Frameworks/libomp.dylib"
for backend_source in /opt/homebrew/opt/ggml/libexec/libggml-*.so; do
  ditto "$backend_source" "$contents/Backends/${backend_source:t}"
done

for executable in "$contents/Helpers/biling-engined" "$contents/Helpers/biling-cli"; do
  install_name_tool -change \
    /opt/homebrew/opt/llama.cpp/lib/libllama.0.dylib \
    @rpath/libllama.0.dylib \
    "$executable"
  install_name_tool -change \
    /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
    @rpath/libggml.0.dylib \
    "$executable"
  install_name_tool -add_rpath @executable_path/../Frameworks "$executable" 2>/dev/null || true
done

install_name_tool -id @rpath/libllama.0.dylib "$contents/Frameworks/libllama.0.dylib"
install_name_tool -change \
  /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
  @rpath/libggml.0.dylib \
  "$contents/Frameworks/libllama.0.dylib"
install_name_tool -id @rpath/libggml.0.dylib "$contents/Frameworks/libggml.0.dylib"
install_name_tool -id @rpath/libggml-base.0.dylib "$contents/Frameworks/libggml-base.0.dylib"
install_name_tool -change \
  /opt/homebrew/opt/libomp/lib/libomp.dylib \
  @rpath/libomp.dylib \
  "$contents/Frameworks/libggml-base.0.dylib"
install_name_tool -id @rpath/libomp.dylib "$contents/Frameworks/libomp.dylib"

for backend in "$contents/Backends/"*.so; do
  install_name_tool -change \
    /opt/homebrew/opt/libomp/lib/libomp.dylib \
    @rpath/libomp.dylib \
    "$backend" 2>/dev/null || true
  install_name_tool -add_rpath @loader_path/../Frameworks "$backend" 2>/dev/null || true
done

codesign --force --deep --sign - \
  --entitlements "$project_root/Resources/BiLing.entitlements" \
  "$bundle"
codesign --verify --deep --strict "$bundle"

# The stable IMKServer initializer uses the bundle's registered connection
# name, so the currently installed process must release it before validation.
launchctl bootout "gui/$(id -u)/$app_label" 2>/dev/null || true
killall BiLingApp 2>/dev/null || true
smoke_log="$staging_root/app-smoke.log"
if ! /usr/bin/perl -e 'alarm 20; exec @ARGV' \
  "$contents/MacOS/BiLingApp" --smoke-test >"$smoke_log" 2>&1; then
    print -u2 "BiLing.app failed its InputMethodKit launch smoke test:"
    tail -n 80 "$smoke_log" >&2
    exit 70
fi
print "InputMethodKit launch smoke test passed."

input_methods_dir="$HOME/Library/Input Methods"
destination="$input_methods_dir/BiLing.app"
backup_dir="$HOME/Library/Application Support/BiLing/Backups"
mkdir -p "$input_methods_dir"
if [[ -e "$destination" ]]; then
  mkdir -p "$backup_dir"
  backup="$backup_dir/BiLing.previous-$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$backup"
  print "Previous installation preserved at $backup"
fi
ditto "$bundle" "$destination"

launch_agents_dir="$HOME/Library/LaunchAgents"
application_support_dir="$HOME/Library/Application Support/BiLing"
mkdir -p "$launch_agents_dir" "$application_support_dir"
launch_plist="$launch_agents_dir/$engine_label.plist"
template="$project_root/Resources/LaunchAgents/$engine_label.plist.in"
sed \
  -e "s|__ENGINE_PATH__|$destination/Contents/Helpers/biling-engined|g" \
  -e "s|__MODEL_PATH__|$destination/Contents/Resources/Models/$model_name|g" \
  -e "s|__BACKEND_PATH__|$destination/Contents/Backends|g" \
  -e "s|__LOG_PATH__|$application_support_dir/engine.log|g" \
  "$template" > "$launch_plist"
plutil -lint "$launch_plist"

launchctl bootout "gui/$(id -u)/$engine_label" 2>/dev/null || true
launchctl enable "gui/$(id -u)/$engine_label"
if ! launchctl bootstrap "gui/$(id -u)" "$launch_plist" 2>/dev/null; then
  # launchd can briefly retain the old Mach service after bootout.
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$launch_plist"
fi
launchctl kickstart -k "gui/$(id -u)/$engine_label"

xpc_smoke_log="$staging_root/qwen-xpc-smoke.log"
if ! /usr/bin/perl -e 'alarm 45; exec @ARGV' \
  "$destination/Contents/Helpers/biling-cli" \
  --xpc jilindaxuelajixuexiao >"$xpc_smoke_log" 2>&1; then
    print -u2 "The installed Qwen XPC service failed its ranking smoke test:"
    tail -n 120 "$xpc_smoke_log" >&2
    exit 70
fi
if ! grep -q '^1\. 吉林大学垃圾学校' "$xpc_smoke_log"; then
  print -u2 "Qwen did not rank 吉林大学垃圾学校 first in the release smoke test:"
  tail -n 40 "$xpc_smoke_log" >&2
  exit 70
fi
print "Qwen XPC ranking smoke test passed."

app_health_log="$staging_root/app-qwen-health.log"
if ! /usr/bin/perl -e 'alarm 40; exec @ARGV' \
  "$destination/Contents/MacOS/BiLingApp" \
  --engine-status-test >"$app_health_log" 2>&1; then
    print -u2 "The installed input-method process could not reach Qwen:"
    tail -n 120 "$app_health_log" >&2
    exit 70
fi
print "Installed-app Qwen health check passed."

original_input_source=$("$destination/Contents/MacOS/BiLingApp" --current-input-source 2>/dev/null || true)
"$destination/Contents/MacOS/BiLingApp" --register-input-source
killall TextInputMenuAgent 2>/dev/null || true
if [[ -n "$original_input_source" ]]; then
  "$destination/Contents/MacOS/BiLingApp" \
    --select-input-source "$original_input_source" 2>/dev/null || true
fi

app_launch_plist="$launch_agents_dir/$app_label.plist"
app_template="$project_root/Resources/LaunchAgents/$app_label.plist.in"
sed \
  -e "s|__APP_PATH__|$destination/Contents/MacOS/BiLingApp|g" \
  -e "s|__LOG_PATH__|$application_support_dir/app.log|g" \
  "$app_template" > "$app_launch_plist"
plutil -lint "$app_launch_plist"
launchctl bootout "gui/$(id -u)/$app_label" 2>/dev/null || true
launchctl enable "gui/$(id -u)/$app_label"
launchctl bootstrap "gui/$(id -u)" "$app_launch_plist"
launchctl kickstart -k "gui/$(id -u)/$app_label"

print ""
print "笔灵已安装。"
print "1. 在菜单栏输入法菜单中选择“笔灵”。"
print "2. 如果列表尚未刷新，请注销并重新登录一次。"
print "3. 笔灵与 Qwen 已设置为登录时自动启动。"
print "4. 设置窗口：open '$destination' --args --preferences"
