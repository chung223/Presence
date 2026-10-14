#!/bin/zsh
# App Store 的 App 預覽影片（iPhone 6.9 吋）：用開發版示範模式的腳本（-PresenceDemoState script）
# 在模擬器上錄影，轉成 App Store 規格：886×1920、30 fps、H.264，加上無聲的立體聲音軌。
# 輸出到 metadata/previews/iphone-6.9/，中英文各一支，約 26 秒。
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
    -derivedDataPath build-sim build -quiet
xcrun simctl install "$sim" build-sim/Build/Products/Debug-iphonesimulator/PresenceRemote.app
xcrun simctl status_bar "$sim" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

out=metadata/previews/iphone-6.9
mkdir -p "$out"
tmp=build-sim/preview-raw  # 原始錄影留著方便除錯（build-sim 不進版控）
mkdir -p "$tmp"

for lang in zh-Hant en-US; do
    case $lang in
        zh-Hant) apple=zh-Hant; locale=zh_TW ;;
        en-US) apple=en; locale=en_US ;;
    esac
    xcrun simctl terminate "$sim" com.chung.presence.remote 2>/dev/null || true
    xcrun simctl io "$sim" recordVideo --codec=h264 --force "$tmp/raw-$lang.mov" >/dev/null 2>&1 &
    recorder=$!
    sleep 2
    xcrun simctl launch "$sim" com.chung.presence.remote -PresenceDemo YES -PresenceDemoState script \
        -AppleLanguages "($apple)" -AppleLocale "$locale" >/dev/null
    sleep 31
    kill -INT $recorder
    wait $recorder || true
    # 錄影開始的時間點每次不同，所以從結尾往回推：結尾畫面是最後一次畫面變化（淡入約 0.6 秒），
    # 腳本從第一句字幕到結尾固定 21 秒（見 RemoteModel.runDemoScript）。
    # 模擬器只在畫面變化時才產生影格，結尾靜止後就沒有新影格，所以先把最後一格延長。
    last=$(ffmpeg -i "$tmp/raw-$lang.mov" -vf "fps=30,select='gt(scene\,0.003)',showinfo" -an -f null - 2>&1 \
        | grep -oE "pts_time:[0-9.]+" | tail -1 | cut -d: -f2)
    start=$(python3 -I -c "print(max(0.0, $last - 0.6 - 21 - 0.6))")
    ffmpeg -v error -y -i "$tmp/raw-$lang.mov" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -vf "fps=30,tpad=stop_mode=clone:stop_duration=8,trim=start=$start:duration=26,setpts=PTS-STARTPTS,scale=886:-2:flags=lanczos,crop=886:1920:0:(ih-1920)/2" \
        -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p -crf 18 -maxrate 12M -bufsize 24M \
        -c:a aac -b:a 256k -shortest -movflags +faststart "$out/presence-remote-$lang.mp4"
    echo "$out/presence-remote-$lang.mp4（從原始錄影的 ${start} 秒開始）"
done

xcrun simctl status_bar "$sim" clear
xcrun simctl shutdown "$sim"
