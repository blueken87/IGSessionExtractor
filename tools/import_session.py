#!/usr/bin/env python3
"""Import an IGSessionExtractor JSON file into instagrapi."""
import json
import sys
from pathlib import Path

from instagrapi import Client


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python import_session.py <ig_session.json>")
        return 2

    path = Path(sys.argv[1])
    settings = json.loads(path.read_text(encoding="utf-8"))

    client = Client()
    client.set_settings(settings)
    try:
        user = client.account_info()
    except Exception as first_error:
        session_id = (settings.get("cookies") or {}).get("sessionid")
        if not session_id:
            raise
        print(f"set_settings failed ({first_error}); retrying with sessionid")
        client = Client()
        client.login_by_sessionid(session_id)
        user = client.account_info()

    output = path.with_suffix(".imported.json")
    client.dump_settings(output)
    print(f"OK: {user.username} ({user.pk})")
    print(f"Saved normalized settings: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
