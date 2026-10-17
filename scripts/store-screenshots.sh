#!/bin/zsh
# App Store 的 iPhone 截圖（6.9 吋）：用開發版示範模式在模擬器上拍，每種語言 5 張。
# 輸出到 metadata/screenshots/iphone-6.9/<語言>/，去掉透明通道（App Store Connect 不收）。
# 用法：scripts/store-screenshots.sh [語言…]（App Store 的語言代碼，不指定就全部重拍）
# 手錶截圖要用真的手錶拍（這台 Mac 沒裝 watchOS 模擬器）：手錶裝開發版、抬起手腕讓螢幕亮著，
# devicectl device process launch … -- -PresenceDemo YES -AppleLanguages "(語言)"，再 devicectl device capture screenshot。
set -euo pipefail
cd "$(dirname "$0")/.."

sim=$(xcrun simctl list devices available | grep "Presence Shots 6.9" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
if [[ -z $sim ]]; then
    sim=$(xcrun simctl create "Presence Shots 6.9" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max \
        com.apple.CoreSimulator.SimRuntime.iOS-27-0)
fi
xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null

xcodebuild -project Presence.xcodeproj -scheme PresenceRemote -destination "platform=iOS Simulator,id=$sim" \
    -derivedDataPath build.noindex/sim build -quiet
xcrun simctl install "$sim" build.noindex/sim/Build/Products/Debug-iphonesimulator/PresenceRemote.app
xcrun simctl status_bar "$sim" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

langs=($@)
(( $#langs )) || langs=(zh-Hant en-US ja ko zh-Hans de-DE fr-FR es-ES)
# 畫面:要不要有 Pro（主畫面拍沒買的樣子，卡片上有 PRO 標記）
shots=(near:NO presenter:YES locked:NO paused:NO onboarding:NO)
for lang in $langs; do
    case $lang in
        zh-Hant) apple=zh-Hant; locale=zh_TW ;;
        en-US) apple=en; locale=en_US ;;
        ja) apple=ja; locale=ja_JP ;;
        ko) apple=ko; locale=ko_KR ;;
        zh-Hans) apple=zh-Hans; locale=zh_CN ;;
        de-DE) apple=de; locale=de_DE ;;
        fr-FR) apple=fr; locale=fr_FR ;;
        es-ES) apple=es; locale=es_ES ;;
    esac
    out=metadata/screenshots/iphone-6.9/$lang
    mkdir -p $out
    i=0
    for shot in $shots; do
        i=$((i + 1))
        state=${shot%%:*}; pro=${shot##*:}
        xcrun simctl terminate "$sim" com.chung.presence.remote 2>/dev/null || true
        xcrun simctl launch "$sim" com.chung.presence.remote -PresenceDemo YES -PresenceDemoState $state \
            -PresencePro $pro -AppleLanguages "($apple)" -AppleLocale "$locale" >/dev/null
        sleep 5
        xcrun simctl io "$sim" screenshot $out/raw.png >/dev/null 2>&1
        ffmpeg -v error -y -i $out/raw.png -pix_fmt rgb24 $out/0$i-$state.png
        rm $out/raw.png
    done
    echo "$out"
done

xcrun simctl status_bar "$sim" clear
