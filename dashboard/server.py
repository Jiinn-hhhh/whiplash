#!/usr/bin/env python3
"""Whiplash Dashboard — HTTP server (stdlib only, zero dependencies)

Usage:
    python3 dashboard/server.py --project myproject [--port 8420]
    → http://localhost:8420
"""
import argparse
import json
import os
import subprocess
import sys
import time
import webbrowser
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DASHBOARD_DIR = Path(__file__).resolve().parent
COLLECTOR = DASHBOARD_DIR / "status-collector.sh"

# Simple cache: (timestamp, data)
_cache = {"time": 0, "data": ""}
CACHE_TTL = 2  # seconds


def collect_status(project: str) -> str:
    """Run status-collector.sh and return JSON string."""
    now = time.time()
    if now - _cache["time"] < CACHE_TTL and _cache["data"]:
        return _cache["data"]

    try:
        result = subprocess.run(
            ["bash", str(COLLECTOR), project],
            capture_output=True,
            text=True,
            timeout=10,
        )
        output = result.stdout.strip()
        if not output:
            output = json.dumps({"error": result.stderr.strip() or "empty output"})
    except subprocess.TimeoutExpired:
        output = json.dumps({"error": "collector timeout"})
    except Exception as e:
        output = json.dumps({"error": str(e)})

    _cache["time"] = now
    _cache["data"] = output
    return output


def make_handler(project: str):
    """Create a request handler class bound to the given project."""

    class DashboardHandler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(DASHBOARD_DIR), **kwargs)

        def do_GET(self):
            parsed = urlparse(self.path)

            if parsed.path == "/api/status":
                qs = parse_qs(parsed.query)
                proj = qs.get("project", [project])[0]
                data = collect_status(proj)

                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(data.encode("utf-8"))
                return

            # Static files: index.html, *.js
            super().do_GET()

        def log_message(self, format, *args):
            # Quieter logging: only errors
            if args and isinstance(args[0], str) and args[0].startswith("GET /api"):
                return  # suppress polling noise
            super().log_message(format, *args)

    return DashboardHandler


def main():
    parser = argparse.ArgumentParser(description="Whiplash Dashboard Server")
    parser.add_argument("--project", required=True, help="Project name")
    parser.add_argument("--port", type=int, default=8420, help="Port (default: 8420)")
    parser.add_argument("--no-open", action="store_true", help="Don't open browser")
    args = parser.parse_args()

    handler = make_handler(args.project)
    server = HTTPServer(("127.0.0.1", args.port), handler)
    url = f"http://localhost:{args.port}"

    print(f"Whiplash Dashboard — {url}")
    print(f"Project: {args.project}")
    print("Press Ctrl+C to stop\n")

    if not args.no_open:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
