#!/usr/bin/env python3
"""原創素材的唯讀 HTTPS 反向代理後端，同時提供 HTTP 外掛與 WebDAV。"""
import argparse
import base64
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, quote, unquote, urlsplit
from xml.sax.saxutils import escape


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "ChaiMusicFixture/1"

    def log_message(self, *_):
        # 不把帳密、查詢文字或完整 URL 輸出至伺服器紀錄。
        pass

    def allowed(self):
        expected = self.server.authorization
        if expected is None or hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="ChaiMusic original fixture"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def payload(self, data, content_type="application/json; charset=utf-8", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.allowed():
            return
        parsed = urlsplit(self.path)
        relative = unquote(parsed.path).lstrip("/")
        if relative.startswith("dav/"):
            relative = relative[4:]
        aliases = {"manifest": "manifest.json", "health": "health.json", "catalog": "catalog.json", "search": "search.json"}
        relative = aliases.get(relative, relative)
        query = parse_qs(parsed.query)
        for endpoint, key in [("stream", "id"), ("lyrics", "recordingID"), ("candidates", "recordingID")]:
            if relative == endpoint and key in query:
                relative = f"{endpoint}/{query[key][0]}.json"
        path = (self.server.root / relative).resolve()
        if not path.is_relative_to(self.server.root) or not path.is_file():
            self.payload(b'{"error":"not_found"}', status=404)
            return
        if path.suffix == ".json":
            value = json.loads(path.read_text())
            if relative.startswith("stream/"):
                value["url"] = self.server.public_base + Path(urlsplit(value["url"]).path).name
            if relative == "search.json" and query.get("q"):
                term = query["q"][0].casefold()
                value["items"] = [item for item in value["items"] if term in (item["title"] + " " + item.get("artist", "")).casefold()]
            self.payload(json.dumps(value, ensure_ascii=False).encode())
            return
        data = path.read_bytes()
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not match:
                self.payload(b"", status=416)
                return
            start = int(match[1]); end = min(len(data) - 1, int(match[2]) if match[2] else len(data) - 1)
            if start > end:
                self.payload(b"", status=416)
                return
            self.send_response(206)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data[start:end + 1])
            return
        self.payload(data, content_type)

    def do_PROPFIND(self):
        if not self.allowed():
            return
        path = unquote(urlsplit(self.path).path)
        if path.rstrip("/") != "/dav":
            self.payload(b"", status=404)
            return
        if self.headers.get("Depth", "1") not in ["0", "1"]:
            self.payload(b"", status=403)
            return
        responses = ['<d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:displayname>ChaiMusic 原創驗證素材</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>']
        if self.headers.get("Depth", "1") == "1":
            for filename in ["low.m4a", "high.flac", "wrong.flac"]:
                item = self.server.root / filename
                if item.is_file():
                    responses.append(f'<d:response><d:href>/dav/{quote(filename)}</d:href><d:propstat><d:prop><d:displayname>{escape(filename)}</d:displayname><d:resourcetype/><d:getcontentlength>{item.stat().st_size}</d:getcontentlength><d:getcontenttype>{mimetypes.guess_type(filename)[0] or "application/octet-stream"}</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        self.payload(('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">' + "".join(responses) + "</d:multistatus>").encode(), "application/xml; charset=utf-8", 207)


def make_server(root, bind="127.0.0.1", port=8787, public_base="https://example.invalid/"):
    root = Path(root).resolve()
    if not (root / "manifest.json").is_file():
        raise ValueError("請先執行 generate_fixtures.py --publish-demo。")
    server = ThreadingHTTPServer((bind, port), FixtureHandler)
    server.root = root
    server.public_base = public_base.rstrip("/") + "/"
    username, password = os.environ.get("FIXTURE_USER"), os.environ.get("FIXTURE_PASSWORD")
    if bool(username) != bool(password):
        raise ValueError("測試來源認證需同時設定 FIXTURE_USER 與 FIXTURE_PASSWORD。")
    server.authorization = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode() if username else None
    return server


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("fixtures/demo"))
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--public-base", required=True)
    args = parser.parse_args()
    if urlsplit(args.public_base).scheme != "https":
        parser.error("App 來源必須經有效憑證的 HTTPS 反向代理提供。")
    server = make_server(args.root, args.bind, args.port, args.public_base)
    print("原創素材伺服器已啟動；正式 App 請透過 HTTPS 反向代理存取。", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
