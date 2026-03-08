#!/usr/bin/env bash
# AutoLab Smart Update Monitor
# Checks openclaw/openclaw GitHub releases for new versions
# Outputs structured JSON with release info for the analyzer
set -euo pipefail

UPDATES_DIR="${HOME}/.autolab/updates"
STATE_FILE="${UPDATES_DIR}/state.json"
CHANGELOGS_DIR="${UPDATES_DIR}/changelogs"
GITHUB_API="https://api.github.com/repos/openclaw/openclaw"

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" << 'EOF'
{
  "last_checked": null,
  "last_seen_tag": null,
  "base_version": "v2026.2.9",
  "applied_versions": [],
  "skipped_versions": [],
  "pending_versions": []
}
EOF
fi

# Read current state
last_seen=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
print(s.get('last_seen_tag') or s.get('base_version', 'v2026.2.9'))
")

base_version=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
print(s.get('base_version', 'v2026.2.9'))
")

echo "=== AutoLab Smart Update Monitor ===" >&2
echo "Base version: $base_version" >&2
echo "Last seen: $last_seen" >&2

# Fetch recent releases (up to 30)
releases_json=$(curl -s "${GITHUB_API}/releases?per_page=30" 2>/dev/null)

if [[ -z "$releases_json" ]] || echo "$releases_json" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, list) else 1)" 2>/dev/null; then
  : # valid JSON array
else
  echo "ERROR: Failed to fetch releases from GitHub API" >&2
  exit 1
fi

# Find new releases since our base version
new_releases=$(python3 -c "
import json, sys, re

releases_json = '''$(echo "$releases_json" | sed "s/'/'\\\\''/g")'''
try:
    releases = json.loads(releases_json)
except:
    with open('/dev/stdin') as f:
        releases = json.loads(f.read())

base = '$base_version'

def version_tuple(tag):
    m = re.match(r'v?(\d+)\.(\d+)\.(\d+)', tag)
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return (0, 0, 0)

base_t = version_tuple(base)
new = []
for r in releases:
    tag = r.get('tag_name', '')
    if version_tuple(tag) > base_t:
        new.append({
            'tag': tag,
            'name': r.get('name', ''),
            'published_at': r.get('published_at', ''),
            'body': r.get('body', ''),
            'prerelease': r.get('prerelease', False),
            'url': r.get('html_url', '')
        })

# Sort oldest first
new.sort(key=lambda x: version_tuple(x['tag']))
print(json.dumps(new, indent=2))
" 2>/dev/null)

release_count=$(echo "$new_releases" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [[ "$release_count" == "0" ]]; then
  echo "UP_TO_DATE: No new releases since $base_version" >&2
  # Update last checked timestamp
  python3 -c "
import json
from datetime import datetime, timezone
with open('$STATE_FILE') as f:
    s = json.load(f)
s['last_checked'] = datetime.now(timezone.utc).isoformat()
with open('$STATE_FILE', 'w') as f:
    json.dump(s, f, indent=2)
"
  echo '{"status": "up_to_date", "releases": []}'
  exit 0
fi

echo "NEW_RELEASES: Found $release_count new release(s) since $base_version" >&2

# Cache changelogs for each new release
echo "$new_releases" | python3 -c "
import json, sys, os
releases = json.load(sys.stdin)
changelogs_dir = '$CHANGELOGS_DIR'
for r in releases:
    tag = r['tag']
    path = os.path.join(changelogs_dir, f'{tag}.md')
    if not os.path.exists(path):
        with open(path, 'w') as f:
            f.write(f'# {r[\"name\"]}\n\n')
            f.write(f'Published: {r[\"published_at\"]}\n\n')
            f.write(r.get('body', ''))
        print(f'  Cached changelog: {tag}', file=sys.stderr)
"

# Update state
python3 -c "
import json
from datetime import datetime, timezone
releases = json.loads('''$(echo "$new_releases" | sed "s/'/'\\\\''/g")''')
with open('$STATE_FILE') as f:
    s = json.load(f)
s['last_checked'] = datetime.now(timezone.utc).isoformat()
if releases:
    s['last_seen_tag'] = releases[-1]['tag']
    # Add to pending if not already tracked
    existing = set(s.get('applied_versions', []) + s.get('skipped_versions', []) + s.get('pending_versions', []))
    for r in releases:
        if r['tag'] not in existing:
            s.setdefault('pending_versions', []).append(r['tag'])
with open('$STATE_FILE', 'w') as f:
    json.dump(s, f, indent=2)
"

# Output structured result
echo "$new_releases" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
print(json.dumps({
    'status': 'new_releases',
    'count': len(releases),
    'base_version': '$base_version',
    'releases': [{'tag': r['tag'], 'published_at': r['published_at'], 'prerelease': r['prerelease']} for r in releases]
}, indent=2))
"
