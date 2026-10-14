#!/bin/zsh
# 宣傳影片（中文、英文，1920×1080、約 37 秒）與 README 用的動圖。
# 片頭 → 離開座位倒數鎖定 → 回來後自動解鎖 → iPhone 與手錶 → 鎖定與解鎖設定 → 在座時間 → 片尾。
# 輸出：build/promo/presence-promo-<語言>.mp4、docs/images/walkaway-<語言>.gif。
# 錄影時 Mac 要保持解鎖，不要碰滑鼠鍵盤（每種語言約 50 秒）。
source "${0:a:h}/common.sh"
icon=Presence/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png
cards=$work/cards
mkdir -p $cards
enc=(-c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -r 30 -an)
calc() { python3 -I -c "print(round($1, 3))"; }

# 共用素材：背景、視窗與手機手錶的遮罩和陰影、錄影時被換掉的紅黃綠按鈕
$bin/card bg $cards/bg.png
$bin/card lights $cards/lights.png
$bin/card frame $cards/mask-win.png 1440 893 38
$bin/card frame $cards/mask-phone.png 586 860 46
$bin/card frame $cards/mask-watch.png 380 465 64
$bin/card shadow $cards/shadow-win.png 240 160 1440 893
$bin/card shadow $cards/shadow-phone.png 437 175 586 860
$bin/card shadow $cards/shadow-watch.png 1103 395 380 465

for lang in zh-Hant en; do
    if [[ $lang == zh-Hant ]]; then
        texts=("離開座位，Mac 自動鎖定；回來，自動解鎖。" "離開座位，倒數幾秒就自動鎖定" "Mac 已鎖定"
               "回來時自動解鎖，手機不用裝 App" "加裝 Presence Remote：iPhone 和手錶一鍵鎖定、暫停"
               "順便記錄你每天在座位上坐了多久" "配對 iPhone 後，偽造藍牙訊號也解不開"
               "Presence · 免費、開源" "macOS 26 以上 · 手機不用裝 App，Presence Remote 為選用")
        store=zh-Hant
    else
        texts=("Walk away and your Mac locks. Come back and it unlocks." "Walk away, and it locks after a short countdown"
               "Mac locked" "Come back and it unlocks. No app needed on your phone."
               "Add Presence Remote to lock or pause from iPhone and Watch" "It even tracks how long you sit at your desk"
               "Pair your iPhone, and a spoofed signal can't unlock your Mac" "Presence · Free and open source"
               "macOS 26 or later · No phone app required · Presence Remote is optional")
        store=en-US
    fi
    $bin/card title $cards/$lang-title.png $icon "Presence" $texts[1]
    $bin/card caption $cards/$lang-c1.png $texts[2]
    $bin/card lock $cards/$lang-lock.png $texts[3]
    $bin/card caption $cards/$lang-c2.png $texts[4]
    $bin/card caption $cards/$lang-c3.png $texts[5]
    $bin/card caption $cards/$lang-c4.png $texts[6]
    $bin/card caption $cards/$lang-c5.png $texts[7]
    $bin/card end $cards/$lang-end.png $icon $texts[8] "github.com/chung223/Presence" $texts[9]

    for section in lockUnlock deskTime; do
        [[ -f $work/shots/$lang-$section.png ]] || scripts/promo/screenshots.sh $section
    done

    # 錄示範腳本（見 Demo.targetRSSI）：約 10 秒開始離開，34 秒回來
    rec=$work/rec-$lang.mov
    demo $lang -PresenceDemoScript YES -PresenceInitialSection overview -PresenceDemoWindowSize 1000x620
    $bin/winrec $demo_window 47 $rec
    demo_quit

    # 從「最近的事件」第一行的變化找出鎖定（L）與解鎖（U）的時間
    changes=($(ffmpeg -i $rec -vf "crop=1800:100:200:1140,fps=10,select='gt(scene\,0.02)',showinfo" -an -f null - 2>&1 \
        | grep -oE "pts_time:[0-9.]+" | cut -d: -f2))
    L=$(printf "%s\n" $changes | awk '$1 > 10 { print; exit }')
    U=$(printf "%s\n" $changes | awk -v l=$L '$1 > l + 5 { print; exit }')
    echo "$lang: 鎖定 $L 秒、解鎖 $U 秒"

    out=$work/build-$lang
    mkdir -p $out
    c=$cards

    # 片頭 3 秒
    ffmpeg -v error -y -framerate 30 -loop 1 -t 3 -i $c/$lang-title.png \
      -vf "scale=3840:-1,zoompan=z='1+0.0004*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,fade=t=in:st=0:d=0.4" \
      -t 3 $enc $out/a.mp4

    # 離開→鎖定→回來→解鎖：兩段錄影中間用鎖定畫面接起來。
    # 錄影時 macOS 會把紅黃綠按鈕換成「正在錄製」標記，蓋上畫好的按鈕
    b0=$(calc "$L - 8.8"); b1=$(calc "$L + 0.6"); c0=$(calc "$U - 1.8"); c1=$(calc "$U + 4.2")
    ffmpeg -v error -y -loop 1 -t 16.8 -i $c/bg.png -loop 1 -i $c/shadow-win.png -i $rec -loop 1 -i $c/mask-win.png \
      -loop 1 -i $c/lights.png -loop 1 -i $c/$lang-c1.png -loop 1 -i $c/$lang-c2.png -loop 1 -i $c/$lang-lock.png -filter_complex "
      [2:v]fps=30,split[r1][r2];
      [r1]trim=start=${b0}:end=${b1},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=1.4[b];
      [r2]trim=start=${c0}:end=${c1},setpts=PTS-STARTPTS[cc];
      [b][cc]concat=n=2:v=1[w0];
      [w0][4:v]overlay=24:24:shortest=1,scale=1440:893:flags=lanczos,format=rgba[w1];
      [3:v]format=gray,scale=1440:893[m];
      [w1][m]alphamerge[win];
      [0:v][1:v]overlay=0:0[s0];
      [s0][win]overlay=240:160:shortest=1[s1];
      [s1][5:v]overlay=0:0:enable='lt(t,10.8)'[s2];
      [s2][6:v]overlay=0:0:enable='gte(t,10.8)'[s3];
      [7:v]format=rgba,fade=t=in:st=8.9:d=0.5:alpha=1,fade=t=out:st=12.3:d=0.4:alpha=1[lock];
      [s3][lock]overlay=0:0:shortest=1,format=yuv420p" -t 16.8 $enc $out/bc.mp4

    # iPhone 與手錶 7 秒：App 預覽影片 14～21 秒（從 iPhone 鎖定、暫停），去掉下方字幕
    ffmpeg -v error -y -loop 1 -t 7 -i $c/bg.png -loop 1 -i $c/shadow-phone.png -loop 1 -i $c/shadow-watch.png \
      -ss 14 -t 7 -i metadata/previews/iphone-6.9/presence-remote-$store.mp4 \
      -loop 1 -i metadata/screenshots/watch-ultra/$store/01-status.png \
      -loop 1 -i $c/mask-phone.png -loop 1 -i $c/mask-watch.png -loop 1 -i $c/$lang-c3.png -filter_complex "
      [3:v]fps=30,crop=886:1300:0:0,scale=586:860:flags=lanczos,format=rgba[p0];
      [5:v]format=gray,scale=586:860[pm]; [p0][pm]alphamerge[phone];
      [4:v]scale=380:465:flags=lanczos,format=rgba[w0];
      [6:v]format=gray,scale=380:465[wm]; [w0][wm]alphamerge[watch];
      [0:v][1:v]overlay=0:0[s0]; [s0][2:v]overlay=0:0[s1];
      [s1][phone]overlay=437:175:shortest=1[s2]; [s2][watch]overlay=1103:395[s3];
      [s3][7:v]overlay=0:0,format=yuv420p" -t 7 $enc $out/d.mp4

    # 截圖 4.5 秒：截圖裡的視窗在 (112,76)、2000×1400，縮成 1240×868 放在 (340,170)，慢慢放大
    shot() {
      ffmpeg -v error -y -framerate 30 -loop 1 -t 4.5 -i $c/bg.png -loop 1 -i $work/shots/$lang-$1.png \
        -loop 1 -i $c/$lang-$2.png -filter_complex "
        [1:v]scale=iw*0.62:-1:flags=lanczos[s];
        [0:v][s]overlay=271:123[s0]; [s0][2:v]overlay=0:0,
        scale=3840:-1,zoompan=z='1+0.00025*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,format=yuv420p" \
        -t 4.5 $enc $out/$3.mp4
    }
    shot lockUnlock c5 f
    shot deskTime c4 e

    # 片尾 4 秒
    ffmpeg -v error -y -loop 1 -t 4 -i $c/$lang-end.png -vf "fade=t=out:st=3.4:d=0.6,format=yuv420p" -t 4 $enc $out/g.mp4

    # 每段之間淡入淡出 0.5 秒；加一條無聲音軌，有些平台要求要有聲音
    ffmpeg -v error -y -i $out/a.mp4 -i $out/bc.mp4 -i $out/d.mp4 -i $out/f.mp4 -i $out/e.mp4 -i $out/g.mp4 \
      -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 -filter_complex "
      [0][1]xfade=transition=fade:duration=0.5:offset=2.5[x1];
      [x1][2]xfade=transition=fade:duration=0.5:offset=18.8[x2];
      [x2][3]xfade=transition=fade:duration=0.5:offset=25.3[x3];
      [x3][4]xfade=transition=fade:duration=0.5:offset=29.3[x4];
      [x4][5]xfade=transition=fade:duration=0.5:offset=33.3,format=yuv420p[v]" \
      -map "[v]" -map 6:a -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -r 30 -c:a aac -b:a 128k -shortest \
      -movflags +faststart $work/presence-promo-$lang.mp4

    # README 開頭的動圖：離開→鎖定→回來→解鎖那一段
    ffmpeg -v error -y -i $out/bc.mp4 -vf "fps=12,scale=1000:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
      docs/images/walkaway-$lang.gif
    echo "$work/presence-promo-$lang.mp4、docs/images/walkaway-$lang.gif"
done
