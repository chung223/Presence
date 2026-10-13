"""整理 String Catalog。新增或修改介面文字後，先建置一次，再執行：

    python3 -I scripts/localization.py

會做三件事：
1. 用建置產生的 .stringsdata 同步 Localizable 與 AppShortcuts 兩個 String Catalog。
2. 每個字串都補上繁體中文（原文）。原文是中文、但找不到時退回英文，
   所以一定要明確產生中文字串表，否則中文環境會顯示英文。
3. 刪掉已經不用的字串，列出還沒有英文翻譯的字串。
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [ROOT / "Presence/Localizable.xcstrings", ROOT / "Presence/AppShortcuts.xcstrings"]
SOURCE = "zh-Hant"


def sync():
    stringsdata = sorted(str(p) for p in (ROOT / "build").rglob("Presence.build/**/*.stringsdata"))
    if not stringsdata:
        sys.exit("找不到 .stringsdata，請先建置：xcodebuild -project Presence.xcodeproj -scheme Presence -derivedDataPath build build")
    subprocess.run(["xcrun", "xcstringstool", "sync", *map(str, CATALOGS), "--stringsdata", *stringsdata], check=True)


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
