"""整理 String Catalog。新增或修改介面文字後，先建置一次，再執行：

    python3 -I scripts/localization.py

要先建置 Mac（輸出到 build/）與 iPhone（輸出到 build-ios/，會一起建置手錶與小工具）：

    xcodebuild -project Presence.xcodeproj -scheme Presence -derivedDataPath build build
    xcodebuild -project Presence.xcodeproj -scheme PresenceRemote -destination 'generic/platform=iOS' \
        -derivedDataPath build-ios -allowProvisioningUpdates build

會做三件事：
1. 用建置產生的 .stringsdata 同步各目標的 String Catalog（見 TARGETS）。
2. 每個字串都補上繁體中文（原文）。原文是中文、但找不到時退回英文，
   所以一定要明確產生中文字串表，否則中文環境會顯示英文。
3. 刪掉已經不用的字串，列出還沒有英文翻譯的字串。
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "zh-Hant"

# 每個建置目標：從哪裡找 .stringsdata、同步到哪些 String Catalog。
# Mac 先建置到 build/，iPhone 與手錶建置到 build-ios/（見 README 的「開發」）。
TARGETS = [
    ("build", "Presence.build", ["Presence/Localizable.xcstrings", "Presence/AppShortcuts.xcstrings"]),
    ("build-ios", "PresenceRemote.build", ["Remote/Localizable.xcstrings", "Remote/AppShortcuts.xcstrings"]),
    ("build-ios", "PresenceRemoteWidgets.build", ["RemoteWidgets/Localizable.xcstrings"]),
    ("build-ios", "PresenceRemoteWatch.build", ["Watch/Localizable.xcstrings"]),
    ("build-ios", "PresenceRemoteWatchWidgets.build", ["WatchWidgets/Localizable.xcstrings"]),
    ("build-ios", "PresenceLink-t.build", ["Packages/PresenceLink/Sources/PresenceLink/Localizable.xcstrings"]),
]
# 手動維護的（Info.plist 的權限說明），只整理不同步
MANUAL = ["Presence/InfoPlist.xcstrings", "Remote/InfoPlist.xcstrings", "Watch/InfoPlist.xcstrings"]
CATALOGS = [ROOT / c for _, _, catalogs in TARGETS for c in catalogs] + [ROOT / c for c in MANUAL]


def sync():
    for build_dir, target, catalogs in TARGETS:
        # 只讀開發版（Debug）的建置：打正式版或封存時留下的 Release 資料可能是舊的，會把刪掉的字串加回來
        stringsdata = sorted(str(p) for p in (ROOT / build_dir).rglob(f"{target}/**/*.stringsdata") if "/Debug" in str(p))
        if not stringsdata:
            sys.exit(f"找不到 {target} 的 .stringsdata，請先建置（輸出到 {build_dir}/）")
        subprocess.run(["xcrun", "xcstringstool", "sync", *(str(ROOT / c) for c in catalogs),
                        "--stringsdata", *stringsdata], check=True)


def tidy(path: Path) -> list[str]:
    data = json.loads(path.read_text())
    untranslated = []
    for key, entry in list(data["strings"].items()):
        if entry.get("extractionState") == "stale":
            del data["strings"][key]
            continue
        localizations = entry.setdefault("localizations", {})
        source = localizations.get(SOURCE)
        if source and "stringSet" in source:
            source["stringSet"]["state"] = "translated"
        elif source and "stringUnit" in source:
            source["stringUnit"]["state"] = "translated"
        elif not entry.get("variations"):
            localizations[SOURCE] = {"stringUnit": {"state": "translated", "value": key}}
        if "en" not in localizations:
            untranslated.append(key)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return untranslated


if __name__ == "__main__":
    sync()
    for catalog in CATALOGS:
        missing = tidy(catalog)
        print(f"{catalog.name}: 沒有英文翻譯的字串 {len(missing)} 個")
        for key in missing:
            print("  ", json.dumps(key, ensure_ascii=False))
