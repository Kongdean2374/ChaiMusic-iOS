"""為原創測試聲音建立與正式來源相同的 ChaiMusic v1 協定。"""
import json
from pathlib import Path
import shutil

RECORDING = "chaimusic-original-fixture-2026-v2"
WRONG = "chaimusic-different-fixture-2026-v2"
AUTHORIZATION = "本音訊與歌詞由 ChaiMusic 專案自行合成創作，以 CC0-1.0 提供測試使用。"


def quality(codec, container, bit_rate=None, depth=None):
    return {"source": "ChaiMusic 原創驗證來源", "container": container, "codec": codec, "bitRate": bit_rate, "sampleRate": 16000, "bitDepth": depth}


def catalog():
    low = {"id": "original-low", "recordingID": RECORDING, "quality": quality("AAC", "M4A", 32000), "alignmentOffset": 0}
    high = {"id": "original-high", "recordingID": RECORDING, "quality": quality("FLAC", "FLAC", depth=16), "alignmentOffset": 0}
    wrong = {"id": "different", "recordingID": WRONG, "quality": quality("FLAC", "FLAC", depth=16), "alignmentOffset": 0}
    return {"items": [
        {"id": "original", "title": "茶間練習 · 原創升級測試", "artist": "ChaiMusic 合成器", "album": "合法驗證素材", "duration": 12, "recordingID": RECORDING, "variants": [low, high]},
        {"id": "different", "title": "另一段旋律 · 錯版拒絕測試", "artist": "ChaiMusic 合成器", "album": "合法驗證素材", "duration": 12, "recordingID": WRONG, "variants": [wrong]}
    ], "complete": True, "nextCursor": None}


def publish(audio_directory, destination, base_url):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    base_url = base_url.rstrip("/") + "/"
    def write(name, payload):
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write("manifest.json", {"schemaVersion": 1, "id": "chaimusic-original-demo", "name": "ChaiMusic 原創驗證來源", "authorization": AUTHORIZATION,
        "health": "health.json", "catalog": "catalog.json", "search": "search.json", "stream": "stream/{id}.json", "lyrics": "lyrics/{recordingID}.json", "candidates": "candidates/{recordingID}.json"})
    write("health.json", {"ok": True})
    page = catalog()
    write("catalog.json", page)
    write("search.json", page)
    for item in page["items"]:
        write(f"candidates/{item['recordingID']}.json", {"recordingID": item["recordingID"], "variants": item["variants"]})
    for identifier, filename, recording in [("original", "low.m4a", RECORDING), ("original-low", "low.m4a", RECORDING), ("original-high", "high.flac", RECORDING), ("different", "wrong.flac", WRONG)]:
        write(f"stream/{identifier}.json", {"url": base_url + filename, "recordingID": recording, "authorization": AUTHORIZATION})
    write(f"lyrics/{RECORDING}.json", {"recordingID": RECORDING, "authorization": AUTHORIZATION, "language": "zh-TW", "lrc": (audio_directory / "lyrics.lrc").read_text(), "translationLRC": (audio_directory / "translation.lrc").read_text()})
    write(f"lyrics/{WRONG}.json", {"recordingID": WRONG, "authorization": AUTHORIZATION, "language": "zh-TW", "text": "這是另一段原創測試旋律，沒有同步歌詞。"})
    for filename in ["low.m4a", "high.flac", "wrong.flac", "lyrics.lrc", "translation.lrc", "fixture-info.json"]:
        shutil.copyfile(audio_directory / filename, destination / filename)
    print(f"已建立可公開部署的原創來源：{destination}")
