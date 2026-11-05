#!/usr/bin/env python3
"""使用固定識別碼產生原生 iOS 專案；不執行建置或測試。"""
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent.parent


def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def make_icon():
    # 原創唱片與柴犬耳朵圖形，沒有外部圖像素材。
    size = 1024
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            dx, dy = x - 512, y - 540
            radius = dx * dx + dy * dy
            color = (19, 23, 34)
            left_ear = 225 <= x <= 420 and 175 <= y <= 445 and y >= 175 + abs(x - 310) * 2
            right_ear = 604 <= x <= 799 and 175 <= y <= 445 and y >= 175 + abs(x - 714) * 2
            if left_ear or right_ear:
                color = (245, 165, 85)
            if radius < 310 * 310:
                color = (235, 155, 75)
            if radius < 250 * 250:
                color = (38, 43, 57)
            if 175 * 175 < radius < 180 * 180 or 218 * 218 < radius < 223 * 223:
                color = (79, 83, 96)
            if radius < 88 * 88:
                color = (255, 205, 132)
            if radius < 24 * 24:
                color = (19, 23, 34)
            row.extend(color)
        rows.append(b"\0" + bytes(row))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    assets = ROOT / "ChaiMusic/Resources/Assets.xcassets"
    icon = assets / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    (icon / "AppIcon.png").write_bytes(png)
    (icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (assets / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')


def generate():
    objects = []
    def obj(key, body):
        objects.append(f"\t\t{uid(key)} = {{ {body} }};")
    sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "ChaiMusic").rglob("*.swift"))
    for source in sources:
        obj("file:" + source, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(source)}; sourceTree = SOURCE_ROOT;")
        obj("build:" + source, f"isa = PBXBuildFile; fileRef = {uid('file:' + source)};")
    obj("assets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "ChaiMusic/Resources/Assets.xcassets"; sourceTree = SOURCE_ROOT;')
    obj("assets-build", f"isa = PBXBuildFile; fileRef = {uid('assets')};")
    obj("plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "ChaiMusic/Resources/Info.plist"; sourceTree = SOURCE_ROOT;')
    obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = ChaiMusic.app; sourceTree = BUILT_PRODUCTS_DIR;')
    children = [uid("file:" + p) for p in sources] + [uid("assets"), uid("plist"), uid("products")]
    obj("group", f"isa = PBXGroup; children = ({','.join(children)}); sourceTree = \"<group>\";")
    obj("products", f"isa = PBXGroup; children = ({uid('product')}); name = Products; sourceTree = \"<group>\";")
    obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(uid('build:' + p) for p in sources)}); runOnlyForDeploymentPostprocessing = 0;")
    obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid('assets-build')}); runOnlyForDeploymentPostprocessing = 0;")
    obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); name = ChaiMusic; productName = ChaiMusic; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
    for scope in ["project", "target"]:
        for config in ["Debug", "Release"]:
            settings = {
                "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
                "CLANG_ENABLE_MODULES": "YES", "SWIFT_STRICT_CONCURRENCY": "targeted",
            }
            if scope == "target":
                settings.update({"PRODUCT_NAME": "ChaiMusic", "PRODUCT_BUNDLE_IDENTIFIER": "app.chai.music", "INFOPLIST_FILE": "ChaiMusic/Resources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "CODE_SIGN_STYLE": "Automatic", "SWIFT_EMIT_LOC_STRINGS": "YES"})
            settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"})
            obj(f"{scope}-{config}", f"isa = XCBuildConfiguration; buildSettings = {{ {' '.join(k + ' = ' + quote(v) + ';' for k, v in settings.items())} }}; name = {config};")
        obj(scope + "-configs", f"isa = XCConfigurationList; buildConfigurations = ({uid(scope+'-Debug')},{uid(scope+'-Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_TW; hasScannedForEncodings = 0; knownRegions = (zh_TW, Base); mainGroup = {uid("group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
    project = ROOT / "ChaiMusic.xcodeproj"
    project.mkdir(exist_ok=True)
    (project / "project.pbxproj").write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {uid("project")};\n}}\n')
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / "ChaiMusic.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="ChaiMusic.app" BlueprintName="ChaiMusic" ReferencedContainer="container:ChaiMusic.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="ChaiMusic.app" BlueprintName="ChaiMusic" ReferencedContainer="container:ChaiMusic.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"已產生 Xcode 專案，收錄 {len(sources)} 個 Swift 檔案。")


if __name__ == "__main__":
    make_icon()
    generate()
