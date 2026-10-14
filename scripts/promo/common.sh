# 截圖與宣傳影片共用：建置開發版、編譯小工具、用示範模式開一份 Presence。
# 由 screenshots.sh、video.sh 以 source 載入。
#
# 示範模式（-PresenceDemo YES）用假裝置與模擬訊號，不接手正在執行的 Presence、不動真正的設定。
# 系統只讓前景的 App 顯示「作用中」的視窗，所以截圖、錄影期間不要碰滑鼠鍵盤，Mac 也要保持解鎖。
set -euo pipefail
cd "${0:a:h}/../.."
repo=$PWD
work=$repo/build/promo
bin=$work/bin
app=$repo/build/Build/Products/Debug/Presence.app
mkdir -p $bin

xcodegen generate >/dev/null
xcodebuild -project Presence.xcodeproj -scheme Presence -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath build build -quiet

# 有頂層程式碼的 Swift 檔要叫 main.swift 才能編譯
for tool in card winrec winid; do
    if [[ ! -x $bin/$tool || scripts/promo/$tool.swift -nt $bin/$tool ]]; then
        mkdir -p $bin/src-$tool
        cp scripts/promo/$tool.swift $bin/src-$tool/main.swift
        swiftc -O $bin/src-$tool/main.swift -o $bin/$tool 2>/dev/null
    fi
done

# demo <語言> <額外參數…>：開一份示範模式的 Presence，設定 $demo_pid 與 $demo_window
demo() {
    local lang=$1; shift
    local locale=$([[ $lang == zh-Hant ]] && echo zh_TW || echo en_US)
    open -n $app --args -PresenceDemo YES -AppleLanguages "($lang)" -AppleLocale $locale "$@"
    sleep 1.5
    demo_pid=$(pgrep -n -f "Debug/Presence.app/Contents/MacOS/Presence")
    demo_window=$($bin/winid $demo_pid | head -1 | cut -d' ' -f1)
}

demo_quit() {
    kill $demo_pid 2>/dev/null || true
    sleep 1
}
