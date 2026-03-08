#!/usr/bin/env python3
"""
AutoLab Smart Update Monitor
Checks openclaw/openclaw GitHub releases for new versions.
Outputs structured JSON to stdout, status messages to stderr.
"""

import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UPDATES_DIR = Path.home() / ".autolab" / "updates"
STATE_FILE = UPDATES_DIR / "state.json"
CHANGELOGS_DIR = UPDATES_DIR / "changelogs"
GITHUB_API = "https://api.github.com/repos/openclaw/openclaw"


def version_tuple(tag):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return (0, 0, 0)


def load_state():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    default = {
        "last_checked": None,
        "last_seen_tag": None,
        "base_version": "v2026.2.9",
        "applied_versions": [],
        "skipped_versions": [],
        "pending_versions": [],
    }
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(default, indent=2))
    return default


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def fetch_releases(per_page=30):
    url = f"{GITHUB_API}/releases?per_page={per_page}"
    req = urllib.request.Request(url, headers={"User-Agent": "autolab-smart-update/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main():
    state = load_state()
    base = state.get("base_version", "v2026.2.9")
    last_seen = state.get("last_seen_tag") or base

    print(f"=== AutoLab Smart Update Monitor ===", file=sys.stderr)
    print(f"Base version: {base}", file=sys.stderr)
    print(f"Last seen: {last_seen}", file=sys.stderr)

    try:
        releases = fetch_releases()
    except Exception as e:
        print(f"ERROR: Failed to fetch releases: {e}", file=sys.stderr)
        json.dump({"status": "error", "error": str(e), "releases": []}, sys.stdout, indent=2)
        sys.exit(1)

    base_t = version_tuple(base)
    new_releases = []

    for r in releases:
        tag = r.get("tag_name", "")
        if version_tuple(tag) > base_t:
            new_releases.append({
                "tag": tag,
                "name": r.get("name", ""),
                "published_at": r.get("published_at", ""),
                "body": r.get("body", ""),
                "prerelease": r.get("prerelease", False),
                "url": r.get("html_url", ""),
            })

    # Sort oldest first
    new_releases.sort(key=lambda x: version_tuple(x["tag"]))

    if not new_releases:
        print(f"UP_TO_DATE: No new releases since {base}", file=sys.stderr)
        state["last_checked"] = datetime.now(timezone.utc).isoformat()
        save_state(state)
        json.dump({"status": "up_to_date", "releases": []}, sys.stdout, indent=2)
        return

    print(f"NEW_RELEASES: Found {len(new_releases)} new release(s) since {base}", file=sys.stderr)

    # Cache changelogs
    CHANGELOGS_DIR.mkdir(parents=True, exist_ok=True)
    for r in new_releases:
        tag = r["tag"]
        path = CHANGELOGS_DIR / f"{tag}.md"
        if not path.exists():
            with open(path, "w") as f:
                f.write(f"# {r['name']}\n\n")
                f.write(f"Published: {r['published_at']}\n\n")
                f.write(r.get("body", ""))
            print(f"  Cached changelog: {tag}", file=sys.stderr)

    # Update state
    state["last_checked"] = datetime.now(timezone.utc).isoformat()
    state["last_seen_tag"] = new_releases[-1]["tag"]
    existing = set(
        state.get("applied_versions", [])
        + state.get("skipped_versions", [])
        + state.get("pending_versions", [])
    )
    for r in new_releases:
        if r["tag"] not in existing:
            state.setdefault("pending_versions", []).append(r["tag"])
    save_state(state)

    # Output structured result
    result = {
        "status": "new_releases",
        "count": len(new_releases),
        "base_version": base,
        "releases": [
            {
                "tag": r["tag"],
                "published_at": r["published_at"],
                "prerelease": r["prerelease"],
            }
            for r in new_releases
        ],
    }
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
