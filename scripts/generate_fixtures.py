#!/usr/bin/env python3
"""產生完全原創、可公開使用的驗證錄音；沒有任何第三方歌曲。"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import wave

RECORDING_ID = "chaimusic-original-fixture-2026-v2"


def synthesize(destination, different=False):
    rate, duration = 16000, 12
    melody = [220, 261.6256, 329.6276, 293.6648, 196, 246.9417, 349.2282, 293.6648]
    if different:
        melody = [196, 293.6648, 220, 349.2282, 261.6256, 329.6276, 246.9417, 220]
    samples = array.array("h")
    phase = 0.0
    for index in range(rate * duration):
        time = index / rate
        note = melody[int(time / 0.43) % len(melody)]
        phase += 2 * math.pi * note / rate
        local = time % 0.43
        envelope = min(1.0, local / 0.018) * min(1.0, (0.43 - local) / 0.055)
        beat = math.exp(-((time % 0.86) * 18))
        signal = envelope * (0.32 * math.sin(phase) + 0.09 * math.sin(phase * 2) + 0.045 * math.sin(phase * 3.006))
        signal += 0.06 * beat * math.sin(2 * math.pi * (58 + 12 * beat) * time)
        signal += 0.003 * math.sin(phase * 5.017) * beat
        signal *= min(1.0, time / 0.1, (duration - time) / 0.2)
        # 單聲道減少測試素材體積，品質提升仍以實際解碼資訊判定。
        value = int(max(-0.95, min(0.95, signal)) * 32767)
        samples.append(value)
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(destination), "wb") as output:
        output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        output.writeframes(samples.tobytes())


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    synthesize(output / "original.wav")
    synthesize(output / "different.wav", different=True)
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(output / "original.wav"), "-c:a", "aac", "-b:a", "32k", "-movflags", "+faststart", str(output / "low.m4a")], check=True)
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(output / "original.wav"), "-c:a", "flac", str(output / "high.flac")], check=True)
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(output / "different.wav"), "-c:a", "flac", str(output / "wrong.flac")], check=True)
    (output / "lyrics.lrc").write_text("[ar:ChaiMusic 測試合成器]\n[ti:茶間練習]\n[00:00.00]<00:00.00>這<00:00.50>是<00:01.00>原創測試聲音\n[00:04.00]<00:04.00>歌詞<00:05.00>跟著時間<00:06.00>前進\n[00:07.00]音源升級後仍維持同一時間軸\n[00:10.00]每一首都完整參與洗牌\n", encoding="utf-8")
    (output / "translation.lrc").write_text("[00:00.00]這是繁體中文測試翻譯\n[00:04.00]翻譯與原文保持同步\n[00:07.00]不因升級重頭開始\n[00:10.00]這是自行創作的測試文字\n", encoding="utf-8")
    manifest = {"recordingID": RECORDING_ID, "license": "CC0-1.0", "duration": 12, "files": {p.name: {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size} for p in sorted(output.iterdir()) if p.is_file() and p.suffix in [".wav", ".flac", ".m4a", ".lrc"]}}
    (output / "fixture-info.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已產生原創 AAC、FLAC、PCM 與錯版對照：{output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("build/fixtures"))
    parser.add_argument("--publish-demo", type=Path)
    parser.add_argument("--base-url", default="https://raw.githubusercontent.com/Kongdean2374/ChaiMusic-iOS/feat/chaimusic-first-build/fixtures/demo/")
    args = parser.parse_args()
    run(args.output)
    if args.publish_demo:
        from fixture_catalog import publish
        publish(args.output, args.publish_demo, args.base_url)
