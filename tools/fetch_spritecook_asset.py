#!/usr/bin/env python3
"""Download a SpriteCook signed asset URL to a local file.

Why this exists: from some networks `api.spritecook.ai` (asset downloads)
is unreachable while `mcp.spritecook.ai` (MCP) works. The script tries the
direct URL first and falls back to the wsrv.nl image proxy with `n=-1`
(no re-encoding), which returns the exact bytes.

Usage:
    python tools/fetch_spritecook_asset.py --url "<signed sprite_url>" \
        --out assets/art/source/sheet.png
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def fetch(url: str, timeout: int = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "WW2AirBattles/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True, help="signed sprite_url from SpriteCook")
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument("--no-proxy", action="store_true", help="fail instead of using wsrv.nl")
    args = parser.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    data = None
    source = "direct"
    try:
        data = fetch(args.url, args.timeout)
    except Exception as exc:  # noqa: BLE001 - network fallback
        print(f"direct download failed: {exc}", file=sys.stderr)
        if args.no_proxy:
            return 1
        source = "wsrv.nl"
        proxied = "https://wsrv.nl/?url=" + urllib.parse.quote(args.url, safe="") + "&n=-1"
        data = fetch(proxied, args.timeout)

    if not data.startswith(b"\x89PNG"):
        print("downloaded bytes are not a PNG", file=sys.stderr)
        return 1

    out.write_bytes(data)
    sha12 = hashlib.sha256(data).hexdigest()[:12]
    print(f"{out} {len(data)} bytes via {source} sha12={sha12}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
