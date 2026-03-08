#!/usr/bin/env bash
# AutoLab Smart Update Orchestrator
# Main entry point that ties monitor → analyzer → patcher together
# Can run unattended (cron) or interactively
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATES_DIR="${HOME}/.autolab/updates"
STATE_FILE="${UPDATES_DIR}/state.json"
REPORTS_DIR="${UPDATES_DIR}/reports"
PATCHES_DIR="${UPDATES_DIR}/patches"
MANIFEST_FILE="${UPDATES_DIR}/manifest.json"
LOG_FILE="${UPDATES_DIR}/update.log"
AUTOLAB_DIR="${HOME}/autolab"

# Ensure directories exist
mkdir -p "$UPDATES_DIR" "$REPORTS_DIR" "$PATCHES_DIR"

# ──────────────────────────────────────────
# Logging
# ──────────────────────────────────────────
log() {
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$ts] $*" | tee -a "$LOG_FILE" >&2
}

# ──────────────────────────────────────────
# Initialize manifest if missing
# ──────────────────────────────────────────
init_manifest() {
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        cat > "$MANIFEST_FILE" << 'EOF'
{
  "created": null,
  "base_version": "v2026.2.9",
  "current_version": "v2026.2.9",
  "entries": []
}
EOF
        python3 -c "
import json
from datetime import datetime, timezone
with open('$MANIFEST_FILE') as f:
    m = json.load(f)
m['created'] = datetime.now(timezone.utc).isoformat()
with open('$MANIFEST_FILE', 'w') as f:
    json.dump(m, f, indent=2)
"
    fi
}

# ──────────────────────────────────────────
# Phase 1: Monitor - Check for new releases
# ──────────────────────────────────────────
phase_monitor() {
    log "Phase 1: Checking for new upstream releases..."
    local result
    result=$(python3 "$SCRIPT_DIR/monitor.py" 2>"$UPDATES_DIR/monitor-stderr.log")

    local status
    status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))")

    if [[ "$status" == "up_to_date" ]]; then
        log "No new releases found."
        echo "$result"
        return 1  # Signal: nothing to do
    fi

    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))")
    log "Found $count new release(s)."
    echo "$result"
    return 0
}

# ──────────────────────────────────────────
# Phase 2: Analyze - Parse changelogs
# ──────────────────────────────────────────
phase_analyze() {
    log "Phase 2: Analyzing changelogs..."
    local result
    result=$(python3 "$SCRIPT_DIR/analyze.py" 2>"$UPDATES_DIR/analyze-stderr.log")

    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))")
    log "Analyzed $count release(s)."

    # Log summary for each
    echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('analyses', []):
    tag = a['tag']
    s = a['summary']
    print(f'  {tag}: {s[\"total\"]} entries, {a[\"high_count\"]} HIGH, {a[\"needs_rebrand\"]} need rebrand', file=sys.stderr)
" 2>&1 | while read -r line; do log "$line"; done

    echo "$result"
}

# ──────────────────────────────────────────
# Phase 3: Patch - Generate and test patches
# ──────────────────────────────────────────
phase_patch() {
    local from_tag="$1"
    local to_tag="$2"

    log "Phase 3: Generating patches ($from_tag → $to_tag)..."

    # Initialize upstream and generate patches
    local patch_dir
    patch_dir=$(bash "$SCRIPT_DIR/patcher.sh" diff "$from_tag" "$to_tag" 2>"$UPDATES_DIR/patcher-stderr.log")

    if [[ -z "$patch_dir" ]] || [[ ! -d "$patch_dir" ]]; then
        log "ERROR: Patch generation failed."
        return 1
    fi

    local patch_file="${patch_dir}/combined-rebranded.patch"
    if [[ ! -f "$patch_file" ]] || [[ ! -s "$patch_file" ]]; then
        log "No changes to apply."
        return 0
    fi

    # Test if patch applies cleanly
    log "Testing patch application..."
    if bash "$SCRIPT_DIR/patcher.sh" test "$patch_file" 2>>"$UPDATES_DIR/patcher-stderr.log"; then
        log "Patch applies cleanly!"
        echo "CLEAN:$patch_file"
    else
        log "Patch has conflicts - generating per-file patches for selective application."
        bash "$SCRIPT_DIR/patcher.sh" per-file "$from_tag" "$to_tag" 2>>"$UPDATES_DIR/patcher-stderr.log"
        echo "CONFLICTS:$patch_file"
    fi
}

# ──────────────────────────────────────────
# Phase 4: Apply - Apply patches on a branch
# ──────────────────────────────────────────
phase_apply() {
    local patch_file="$1"
    local from_tag="$2"
    local to_tag="$3"
    local branch="update/${to_tag}"

    log "Phase 4: Applying patch on branch $branch..."

    if bash "$SCRIPT_DIR/patcher.sh" apply "$patch_file" "$branch" 2>>"$UPDATES_DIR/patcher-stderr.log"; then
        log "Patch applied successfully on branch $branch!"

        # Update manifest
        python3 -c "
import json
from datetime import datetime, timezone
with open('$MANIFEST_FILE') as f:
    m = json.load(f)
m['entries'].append({
    'from_tag': '$from_tag',
    'to_tag': '$to_tag',
    'branch': '$branch',
    'status': 'applied',
    'applied_at': datetime.now(timezone.utc).isoformat(),
    'patch_file': '$patch_file'
})
m['current_version'] = '$to_tag'
with open('$MANIFEST_FILE', 'w') as f:
    json.dump(m, f, indent=2)
"
        # Update state
        python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
tag = '$to_tag'
if tag in s.get('pending_versions', []):
    s['pending_versions'].remove(tag)
s.setdefault('applied_versions', []).append(tag)
s['base_version'] = tag
with open('$STATE_FILE', 'w') as f:
    json.dump(s, f, indent=2)
"
        return 0
    else
        log "Patch application failed on branch $branch"
        # Record failure in manifest
        python3 -c "
import json
from datetime import datetime, timezone
with open('$MANIFEST_FILE') as f:
    m = json.load(f)
m['entries'].append({
    'from_tag': '$from_tag',
    'to_tag': '$to_tag',
    'branch': '$branch',
    'status': 'failed',
    'failed_at': datetime.now(timezone.utc).isoformat(),
    'patch_file': '$patch_file'
})
with open('$MANIFEST_FILE', 'w') as f:
    json.dump(m, f, indent=2)
"
        return 1
    fi
}

# ──────────────────────────────────────────
# Generate summary report for Telegram/output
# ──────────────────────────────────────────
generate_summary() {
    log "Generating summary report..."

    python3 -c "
import json, os

updates_dir = '$UPDATES_DIR'
reports_dir = '$REPORTS_DIR'
state_file = '$STATE_FILE'
manifest_file = '$MANIFEST_FILE'

# Load state
with open(state_file) as f:
    state = json.load(f)

# Load manifest
if os.path.exists(manifest_file):
    with open(manifest_file) as f:
        manifest = json.load(f)
else:
    manifest = {'entries': [], 'current_version': state.get('base_version', 'unknown')}

pending = state.get('pending_versions', [])
applied = state.get('applied_versions', [])

lines = ['📋 **AutoLab Update Report**', '']
lines.append(f'Current version: \`{manifest.get(\"current_version\", \"unknown\")}\`')
lines.append(f'Pending updates: {len(pending)}')
lines.append(f'Applied updates: {len(applied)}')
lines.append('')

# For each pending, show analysis summary
for tag in pending:
    report_file = os.path.join(reports_dir, f'{tag}-analysis.json')
    if os.path.exists(report_file):
        with open(report_file) as f:
            analysis = json.load(f)
        s = analysis.get('summary', {})
        lines.append(f'**{tag}** — {s.get(\"total\", 0)} changes:')
        lines.append(f'  🔒 Security: {s.get(\"security_count\", 0)}')
        lines.append(f'  🔧 Bugs: {s.get(\"by_category\", {}).get(\"BUGFIX\", 0)}')
        lines.append(f'  ✨ Features: {s.get(\"by_category\", {}).get(\"FEATURE\", 0)}')
        lines.append(f'  🏷️ Need rebrand: {s.get(\"needs_rebrand_count\", 0)}')
        ha = s.get('by_action', {})
        lines.append(f'  → AUTO_APPLY: {ha.get(\"AUTO_APPLY\", 0)}, REVIEW: {ha.get(\"REVIEW\", 0)}, SKIP: {ha.get(\"SKIP\", 0)}')
        lines.append('')

print('\n'.join(lines))
"
}

# ──────────────────────────────────────────
# Main commands
# ──────────────────────────────────────────
case "${1:-run}" in
    run)
        # Full pipeline: monitor → analyze → report
        # Does NOT auto-apply (safe for cron)
        init_manifest
        log "=== Starting Smart Update Pipeline ==="

        # Phase 1: Monitor
        monitor_result=$(phase_monitor) || {
            log "=== Pipeline complete: up to date ==="
            exit 0
        }

        # Phase 2: Analyze
        analyze_result=$(phase_analyze)

        # Phase 3: Generate patches (from base to latest pending)
        base_version=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('base_version','v2026.2.9'))")
        latest_pending=$(python3 -c "
import json
s = json.load(open('$STATE_FILE'))
p = s.get('pending_versions', [])
print(p[-1] if p else '')
")

        if [[ -n "$latest_pending" ]]; then
            patch_result=$(phase_patch "$base_version" "$latest_pending")
            log "Patch result: $patch_result"
        fi

        # Generate summary report
        summary=$(generate_summary)
        echo "$summary"
        echo "$summary" > "$UPDATES_DIR/latest-report.md"

        log "=== Pipeline complete ==="
        ;;

    apply-pending)
        # Apply all pending patches that pass clean test
        init_manifest
        base_version=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('base_version','v2026.2.9'))")
        pending=$(python3 -c "import json; print(' '.join(json.load(open('$STATE_FILE')).get('pending_versions',[])))")

        if [[ -z "$pending" ]]; then
            log "No pending updates to apply."
            exit 0
        fi

        for tag in $pending; do
            log "Processing $tag..."
            patch_dir="${PATCHES_DIR}/${base_version}__${tag}"
            patch_file="${patch_dir}/combined-rebranded.patch"

            if [[ ! -f "$patch_file" ]]; then
                log "Generating patch for $base_version → $tag..."
                phase_patch "$base_version" "$tag"
            fi

            if [[ -f "$patch_file" ]] && [[ -s "$patch_file" ]]; then
                if phase_apply "$patch_file" "$base_version" "$tag"; then
                    base_version="$tag"  # Chain patches
                    log "Successfully applied $tag"
                else
                    log "Failed to apply $tag — stopping chain"
                    break
                fi
            fi
        done
        ;;

    check)
        # Just check for new releases (no analyze/patch)
        init_manifest
        phase_monitor
        ;;

    analyze)
        # Analyze pending releases
        phase_analyze
        ;;

    report)
        # Generate and display report
        generate_summary
        ;;

    status)
        # Show current state
        python3 -c "
import json, os

state_file = '$STATE_FILE'
manifest_file = '$MANIFEST_FILE'

if os.path.exists(state_file):
    with open(state_file) as f:
        s = json.load(f)
    print(f'Base version: {s.get(\"base_version\", \"unknown\")}')
    print(f'Last checked: {s.get(\"last_checked\", \"never\")}')
    print(f'Last seen tag: {s.get(\"last_seen_tag\", \"none\")}')
    print(f'Pending: {s.get(\"pending_versions\", [])}')
    print(f'Applied: {s.get(\"applied_versions\", [])}')
    print(f'Skipped: {s.get(\"skipped_versions\", [])}')
else:
    print('No state file found. Run the pipeline first.')

if os.path.exists(manifest_file):
    with open(manifest_file) as f:
        m = json.load(f)
    print(f'\\nManifest entries: {len(m.get(\"entries\", []))}')
    for e in m.get('entries', [])[-5:]:
        print(f'  {e[\"from_tag\"]} → {e[\"to_tag\"]}: {e[\"status\"]}')
"
        ;;

    help|*)
        echo "AutoLab Smart Update Orchestrator"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  run             Full pipeline: monitor → analyze → patch → report (safe, no auto-apply)"
        echo "  apply-pending   Apply all pending patches that pass clean test"
        echo "  check           Just check for new releases"
        echo "  analyze         Analyze pending changelogs"
        echo "  report          Generate and display summary report"
        echo "  status          Show current state and manifest"
        echo "  help            Show this help"
        ;;
esac
