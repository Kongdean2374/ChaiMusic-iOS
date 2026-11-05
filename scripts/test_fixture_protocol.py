#!/usr/bin/env python3
"""有界的本機 fixture 協定測試；不代表 iOS client 或音訊播放已驗收。"""
import json
import os
from pathlib import Path
import sys
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
from fixture_server import make_server


def check(root):
    # 測試只聽 loopback 隨機 port；不建立對外服務。
    server = make_server(root, port=0)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        def get(path, method="GET", headers=None):
            request_headers = dict(headers or {})
            if server.authorization:
                request_headers["Authorization"] = server.authorization
            with urlopen(Request(base + path, method=method, headers=request_headers), timeout=5) as response:
                return response.status, response.read()
        manifest = json.loads(get("/manifest.json")[1])
        assert manifest["schemaVersion"] == 1 and manifest["authorization"]
        assert json.loads(get("/health.json")[1])["ok"]
        catalog = json.loads(get("/catalog.json")[1])
        assert catalog["complete"] and len(catalog["items"]) == 2
        assert len(json.loads(get("/search?q=%E8%8C%B6%E9%96%93")[1])["items"]) == 1
        original = catalog["items"][0]
        assert len(original["variants"]) == 2
        for variant in original["variants"]:
            stream = json.loads(get("/stream/" + variant["id"] + ".json")[1])
            assert stream["url"].startswith("https://") and stream["recordingID"] == original["recordingID"]
        lyrics = json.loads(get("/lyrics/" + original["recordingID"] + ".json")[1])
        assert lyrics["authorization"] and "[00:" in lyrics["lrc"] and lyrics["translationLRC"]
        candidates = json.loads(get("/candidates/" + original["recordingID"] + ".json")[1])
        assert len(candidates["variants"]) == 2
        status, data = get("/dav/", "PROPFIND", {"Depth": "1"})
        assert status == 207
        assert len(ET.fromstring(data).findall("{DAV:}response")) == 4
        status, head = get("/dav/low.m4a", headers={"Range": "bytes=0-31"})
        assert status == 206 and len(head) == 32
        try:
            get("/%2e%2e/README.md")
            raise AssertionError("不應允許路徑穿越")
        except HTTPError as error:
            assert error.code == 404
        print("Fixture manifest／完整 catalog／搜尋／stream／歌詞／候選／WebDAV／Range／路徑限制通過。")
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    check(Path(sys.argv[1] if len(sys.argv) > 1 else "fixtures/demo"))
