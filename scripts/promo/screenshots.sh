#!/bin/zsh
# Mac 版各頁截圖（中文、英文），輸出到 docs/images/mac/，README 用。
# 用法：scripts/promo/screenshots.sh [頁面…]（不指定就全部重拍）。約需 2 分鐘，期間不要碰滑鼠鍵盤。
source "${0:a:h}/common.sh"
sections=($@)
(( $#sections )) || sections=(overview devices lockUnlock context deskTime history)
mkdir -p $work/shots docs/images/mac
for lang in zh-Hant en; do
    for section in $sections; do
        demo $lang -PresenceInitialSection $section -PresenceDemoWindowSize 1000x700
        sleep 4.5   # 等模擬訊號讓狀態變成「在附近」
        screencapture -x -l$demo_window $work/shots/$lang-$section.png
        demo_quit
        sips -Z 1400 $work/shots/$lang-$section.png --out docs/images/mac/$lang-$section.png >/dev/null
        echo "docs/images/mac/$lang-$section.png"
    done
done
