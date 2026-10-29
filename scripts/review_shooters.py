#!/usr/bin/env python3
"""Temporary, loopback-only developer review UI. No BHE UI/database integration."""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from basketball_highlight.shooter_labels import normalize_shot_label


def validate_label(label, predictions):
    if not isinstance(label, dict):
        raise ValueError("Label must be an object")
    result = next(
        (
            r
            for r in predictions["results"]
            if r["candidate_id"] == label.get("candidate_id")
            and r["tracking_scope"] == label.get("tracking_scope")
        ),
        None,
    )
    if result is None:
        raise ValueError("Candidate/session changed. Reload the review page.")
    allowed = {
        t["track_id"]
        for s in predictions["sessions"]
        if s["tracking_scope"] == result["tracking_scope"]
        for t in s["tracks"]
    }
    track_id = label.get("shooter_track_id")
    if track_id is not None and (
        isinstance(track_id, bool)
        or not isinstance(track_id, int)
        or track_id not in allowed
    ):
        raise ValueError("Select a track from this session")
    canonical = normalize_shot_label(label)
    return {
        "candidate_id": result["candidate_id"],
        "tracking_scope": result["tracking_scope"],
        "label_schema_version": 2,
        "is_shot": canonical["is_shot"],
        "shot_outcome": canonical["shot_outcome"],
        "is_scoring": canonical["is_scoring"],
        "shooter_track_id": track_id,
        "review_kind": "scoped_shooter"
        if track_id is not None
        else "unresolvable"
        if canonical["is_shot"] is True
        else "not_shot"
        if canonical["is_shot"] is False
        else "legacy_not_made_unclassified",
        "note": str(label.get("note", ""))[:1000],
        **{k: canonical[k] for k in ("player_id", "attempt_id") if k in canonical},
    }


def make_server(predictions, video, labels_path, port):
    lock = threading.Lock()
    labels = (
        json.loads(labels_path.read_text(encoding="utf-8"))
        if labels_path.is_file()
        else []
    )
    html_path = Path(__file__).with_name("shooter_review.html")

    class Handler(BaseHTTPRequestHandler):
        def send_json(self, data, status=200):
            body = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/predictions":
                return self.send_json(predictions)
            if path == "/labels":
                with lock:
                    return self.send_json(labels)
            if path == "/":
                html = html_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(html)
                return
            if path != "/video":
                return self.send_error(404)
            size = video.stat().st_size
            start, end = 0, size - 1
            byte_range = self.headers.get("Range")
            if byte_range:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", byte_range)
                if not match:
                    return self.send_error(416)
                start, end = (
                    int(match[1]),
                    min(int(match[2]) if match[2] else size - 1, size - 1),
                )
                if start >= size or end < start:
                    return self.send_error(416)
            self.send_response(206 if byte_range else 200)
            self.send_header(
                "Content-Type", mimetypes.guess_type(video.name)[0] or "video/mp4"
            )
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if byte_range:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            try:
                with video.open("rb") as stream:
                    stream.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        chunk = stream.read(min(256 * 1024, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            # Browsers from other origins cannot write review labels. Only the
            # fixed labels file is writable; no user-supplied filesystem paths.
            origin = self.headers.get("Origin")
            expected = f"http://{self.headers.get('Host')}"
            if (
                self.path != "/labels"
                or origin != expected
                or self.headers.get("Content-Type") != "application/json"
            ):
                return self.send_error(403)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 10000:
                    raise ValueError("Invalid request size")
                label = validate_label(json.loads(self.rfile.read(length)), predictions)
                with lock:
                    updated = [
                        item
                        for item in labels
                        if (item["candidate_id"], item["tracking_scope"])
                        != (label["candidate_id"], label["tracking_scope"])
                    ] + [label]
                    labels_path.parent.mkdir(parents=True, exist_ok=True)
                    temporary = labels_path.with_suffix(".tmp")
                    temporary.write_text(
                        json.dumps(updated, indent=2, ensure_ascii=False),
                        encoding="utf-8",
                    )
                    temporary.replace(labels_path)
                    labels[:] = updated
                return self.send_json(
                    {"saved": True, "count": len(labels), "label": label}
                )
            except (ValueError, KeyError, TypeError) as exc:
                return self.send_json({"error": str(exc)}, 400)

        def log_message(self, *args):
            pass

    class LocalReviewServer(ThreadingHTTPServer):
        def server_bind(self):
            # HTTPServer's default bind does reverse DNS, which can hang on
            # offline machines. This tool only listens on numeric loopback.
            TCPServer.server_bind(self)
            self.server_name = "127.0.0.1"
            self.server_port = self.server_address[1]

    return LocalReviewServer(("127.0.0.1", port), Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument(
        "--video",
        type=Path,
        required=True,
        help="Source or same-timeline browser-compatible proxy",
    )
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not args.video.is_file():
        parser.error("Video does not exist")
    predictions = json.loads(args.predictions.read_text(encoding="utf-8"))
    server = make_server(predictions, args.video, args.labels, args.port)
    print(f"review_url=http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
