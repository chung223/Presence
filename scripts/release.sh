#!/bin/zsh
# 發佈 Mac 版：Developer ID 簽章 → Apple 公證 → 釘上公證票據 → Sparkle 更新清單 → GitHub Release 草稿。
#
#   1. 改 project.yml 的 MARKETING_VERSION（給人看）與 CURRENT_PROJECT_VERSION（Sparkle 比大小用，每版 +1）
#   2. scripts/release.sh
#   3. 到 GitHub 檢查草稿、寫更新說明後按 Publish；發佈後 Sparkle 才看得到
#
# 需要：Developer ID Application 憑證、asc 已登入（公證用）、gh 已登入、
#       鑰匙圈裡有 Sparkle 的 EdDSA 私鑰（scripts 第一次用 generate_keys 產生）。
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/^ *MARKETING_VERSION: "(.*)"/\1/p' project.yml | head -1)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "(.*)"/\1/p' project.yml | head -1)
tag="v$version"
out="build/release/$version"
sparkle="build/SourcePackages/artifacts/sparkle/Sparkle/bin"

if gh release view "$tag" >/dev/null 2>&1; then
    echo "GitHub 已經有 $tag，請先改版本號" >&2
    exit 1
fi

echo "== Presence $version ($build)"
rm -rf "$out"
mkdir -p "$out/updates"
xcodegen generate >/dev/null

echo "== 封存（Release，Developer ID）"
xcodebuild archive -project Presence.xcodeproj -scheme Presence -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build \
    -archivePath "$out/Presence.xcarchive" -quiet

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>52A8DH7GF9</string>
</dict>
</plist>
PLIST

echo "== 匯出"
xcodebuild -exportArchive -archivePath "$out/Presence.xcarchive" \
    -exportPath "$out/export" -exportOptionsPlist "$out/ExportOptions.plist" -quiet
app="$out/export/Presence.app"
codesign --verify --deep --strict "$app"

echo "== 公證（通常幾分鐘）"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
asc notarization submit --file "$out/notarize.zip" --wait --poll-interval 20s --timeout 30m
xcrun stapler staple "$app"
spctl --assess --type execute "$app"

echo "== Sparkle 更新清單"
ditto -c -k --keepParent "$app" "$out/updates/Presence-$version.zip"
"$sparkle/generate_appcast" \
    --download-url-prefix "https://github.com/chung223/Presence/releases/download/$tag/" \
    "$out/updates"

echo "== GitHub Release 草稿"
gh release create "$tag" --draft --title "Presence $version" \
    --notes "Presence $version。下載 Presence-$version.zip，解壓縮後拖進「應用程式」資料夾。" \
    "$out/updates/Presence-$version.zip" "$out/updates/appcast.xml"

echo "完成：到 GitHub 檢查草稿後按 Publish。"
