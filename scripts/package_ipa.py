#!/usr/bin/env python3
"""驗證實機產物與動態依賴，成功後才建立並檢查未簽署 IPA。"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def is_macho(path):
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return stream.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf")


def expand_path(value, image, executable):
    return Path(value.replace("@loader_path", str(image.parent)).replace("@executable_path", str(executable.parent))).resolve()


def run(app, output):
    app = app.resolve()
    require(app.is_dir() and app.name == "ChaiMusic.app", "找不到原生 ChaiMusic.app。")
    info_path = app / "Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    expected = {
        "CFBundleIdentifier": "app.chai.music", "CFBundleName": "ChaiMusic",
        "CFBundleDisplayName": "柴音樂", "CFBundlePackageType": "APPL",
        "CFBundleDevelopmentRegion": "zh_TW",
        "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
        "CFBundleExecutable": "ChaiMusic", "CFBundleInfoDictionaryVersion": "6.0",
        "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1],
        "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
        "LSSupportsOpeningDocumentsInPlace": True, "UIUserInterfaceStyle": "Dark",
    }
    for key, value in expected.items():
        require(info.get(key) == value, f"Info.plist 不符：{key}，實際為 {info.get(key)!r}。")
    require(info.get("MinimumOSVersion") == "17.0", "最低版本必須是 iOS 17.0。")
    require("audio" in info.get("UIBackgroundModes", []), "缺少背景音訊設定。")
    require("zh_TW" in info.get("CFBundleLocalizations", []), "缺少繁體中文設定。")
    require(info.get("UISupportedInterfaceOrientations") == ["UIInterfaceOrientationPortrait"], "直向設定不完整。")
    require(isinstance(info.get("UILaunchScreen"), dict), "缺少原生啟動畫面設定。")
    require(str(info.get("DTSDKName", "")).startswith("iphoneos"), "SDK 必須是實機 iPhoneOS。")
    for key in ["DTCompiler", "DTPlatformBuild", "DTPlatformVersion", "DTSDKBuild", "DTXcode", "DTXcodeBuild"]:
        require(bool(info.get(key)), f"缺少 Xcode 產物資訊：{key}。")
    primary_icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    require(primary_icon.get("CFBundleIconName") == "AppIcon", "缺少 AppIcon 宣告。")
    icon_files = primary_icon.get("CFBundleIconFiles", [])
    require(bool(icon_files), "缺少編譯圖示清單。")
    for icon in icon_files:
        require(any(app.glob(icon + "*.png")), f"缺少編譯圖示檔：{icon}。")
    require((app / "Assets.car").is_file(), "缺少編譯資源。")
    executable = app / info["CFBundleExecutable"]
    require(is_macho(executable) and os.access(executable, os.X_OK), "主程式不是可執行 Mach-O。")
    require("EXECUTE" in command("xcrun", "otool", "-hv", str(executable)), "主程式不是 MH_EXECUTE。")
    all_files = sorted(path for path in app.rglob("*") if path.is_file())
    require(not any(path.is_symlink() for path in app.rglob("*")), "封裝不接受未解析的符號連結。")
    images = [path for path in all_files if is_macho(path)]
    require(executable in images, "主程式不在封裝內容中。")
    load_commands = {}
    rpaths = {}
    for image in images:
        architectures = command("xcrun", "lipo", "-archs", str(image)).strip().split()
        require(architectures == ["arm64"], f"非純 arm64 實機映像：{image.name}。")
        loads = command("xcrun", "otool", "-l", str(image))
        load_commands[image] = loads
        platforms = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\S+)", loads)
        require(platforms and all(value in ["IOS", "2"] for value in platforms), f"缺少 iOS LC_BUILD_VERSION 或包含模擬器映像：{image.name}。")
        rpaths[image] = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", loads)
    for image in images:
        # -L 的第一行是映像名稱；DYLIB 的下一行是自身 install name。
        dependencies = [line.strip().split(" (compatibility version", 1)[0] for line in command("xcrun", "otool", "-L", str(image)).splitlines()[1:] if line.strip()]
        own_ids = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.+?) \(offset", load_commands[image])
        for dependency in dependencies:
            if dependency in own_ids or dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if dependency.startswith("@rpath/"):
                relative = dependency[len("@rpath/"):]
                candidates = [expand_path(base, image, executable) / relative for base in rpaths[image]]
                candidates += [expand_path(base, executable, executable) / relative for base in rpaths[executable]]
            else:
                candidates = [expand_path(dependency, image, executable)]
            candidates = [candidate.resolve() for candidate in candidates]
            bundled = [candidate for candidate in candidates if candidate.is_relative_to(app) and candidate.is_file()]
            require(bool(bundled), f"缺少內嵌依賴：{image.name} → {dependency}。")
            require(any(candidate in images for candidate in bundled), f"依賴不是真實 Mach-O：{dependency}。")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".ipa.partial")
    output.unlink(missing_ok=True)
    temporary.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in all_files:
                archive.write(path, "Payload/ChaiMusic.app/" + path.relative_to(app).as_posix())
        with zipfile.ZipFile(temporary) as archive:
            require(archive.testzip() is None, "ZIP CRC 驗證失敗。")
            expected_names = {"Payload/ChaiMusic.app/" + path.relative_to(app).as_posix() for path in all_files}
            require(set(archive.namelist()) == expected_names, "ZIP 封裝內容不完整。")
            require(len(archive.namelist()) == len(expected_names), "ZIP 含有重複路徑。")
            for path in all_files:
                name = "Payload/ChaiMusic.app/" + path.relative_to(app).as_posix()
                require(hashlib.sha256(archive.read(name)).digest() == hashlib.sha256(path.read_bytes()).digest(), f"封裝前後內容不一致：{name}。")
            require(plistlib.loads(archive.read("Payload/ChaiMusic.app/Info.plist")) == info, "封裝 plist 不一致。")
            mode = archive.getinfo("Payload/ChaiMusic.app/ChaiMusic").external_attr >> 16
            require(mode & 0o111, "ZIP 沒有保存主程式執行權限。")
        temporary.replace(output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    print(f"實機 Mach-O、iOS 平台、完整 plist、{len(images)} 個二進位映像、動態依賴與 ZIP 完整性驗證成功。")
    print(f"未簽署 IPA：{output}；必須自行簽署才能安裝到 iPhone。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        run(args.app, args.output)
    except Exception as error:
        print(f"產物驗證失敗：{error}", file=sys.stderr)
        sys.exit(1)
