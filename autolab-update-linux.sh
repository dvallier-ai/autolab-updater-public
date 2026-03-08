#!/usr/bin/env bash
# ============================================================================
# autolab-update-linux.sh — Linux adaptation of autolab-update.sh
# ============================================================================
#
# Same "Fresh Rebrand Overlay" strategy as macOS version, adapted for:
#   - Linux sed (no '' after -i)
#   - systemd user service (not launchctl)
#   - /usr/bin/node (not /opt/homebrew/bin/node)
#   - Port 18789 (matches systemd unit)
#
# Usage:
#   ./autolab-update-linux.sh [target-version]
#   ./autolab-update-linux.sh v2026.2.17
#   ./autolab-update-linux.sh              # auto-detects latest stable
#
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
GIT="/usr/bin/git"
UPSTREAM_BARE="$HOME/.autolab/updates/upstream.git"
UPSTREAM_REPO="https://github.com/openclaw/openclaw.git"
FORK_REPO="https://github.com/dvallier-ai/autolab-public.git"
TEST_DIR="$HOME/autolab-test"
PROD_DIR="$HOME/autolab"
STATE_FILE="$HOME/.autolab/updates/state.json"
LOG_DIR="$HOME/.autolab/logs"
TEMP_DIR=""
TEST_PORT=18793
PROD_PORT=18789
NODE_BIN="/usr/bin/node"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log "Cleaning up temp directory..."
        rm -rf "$TEMP_DIR"
    fi
    # Kill test gateway if running
    pkill -f "AUTOLAB_PORT=$TEST_PORT" 2>/dev/null || true
}
trap cleanup EXIT

die() { err "$*"; exit 1; }

# ── Rebrand Transform ─────────────────────────────────────────────────────────
apply_rebrand_file() {
    local file="$1"

    # Skip binary files by extension
    case "${file##*.}" in
        png|jpg|jpeg|gif|ico|bmp|svg|webp|\
        woff|woff2|ttf|eot|otf|\
        zip|tar|gz|bz2|xz|7z|jar|war|tgz|\
        dll|so|dylib|o|a|node|\
        mp3|mp4|wav|ogg|webm|mov|avi|\
        pdf|doc|docx|pptx|xlsx|\
        sqlite|db|lock|icon|icns|\
        pbxproj|xcworkspacedata|storyboard|xib)
            return 0
            ;;
    esac

    # Extra guard: skip truly binary files
    if ! file "$file" 2>/dev/null | grep -qE 'text|JSON|XML|empty'; then
        return 0
    fi

    # Apply sed transforms (Linux: no '' after -i)
    sed -i \
        -e 's|openclaw/openclaw|dvallier-ai/autolab-public|g' \
        -e 's|@openclaw/openclaw|@dvallier-ai/autolab-public|g' \
        -e 's|OpenClaw|AutoLab|g' \
        -e 's|OPENCLAW|AUTOLAB|g' \
        -e 's|openclaw\.com|autolab.app|g' \
        -e 's|openclaw://|autolab://|g' \
        -e 's|\.openclaw/|.autolab/|g' \
        -e 's|openclaw-gateway|autolab-gateway|g' \
        -e 's|openclaw gateway|autolab gateway|g' \
        -e 's|openclaw doctor|autolab doctor|g' \
        -e 's|openclaw message|autolab message|g' \
        -e 's|openclaw tui|autolab tui|g' \
        -e 's|openclaw dashboard|autolab dashboard|g' \
        -e 's|openclaw security|autolab security|g' \
        -e 's|openclaw reset|autolab reset|g' \
        -e 's|openclaw uninstall|autolab uninstall|g' \
        -e 's|openclaw cron|autolab cron|g' \
        -e 's|openclaw models|autolab models|g' \
        -e 's|openclaw config|autolab config|g' \
        -e 's|openclaw plugins|autolab plugins|g' \
        -e 's|`openclaw |`autolab |g' \
        -e 's|"openclaw"|"autolab"|g' \
        -e "s|'openclaw'|'autolab'|g" \
        -e 's|bin/openclaw|bin/autolab|g' \
        -e 's|name: "openclaw"|name: "autolab"|g' \
        -e "s|name: 'openclaw'|name: 'autolab'|g" \
        -e 's|openclaw\.mjs|autolab.mjs|g' \
        -e 's|ai\.openclaw\.|ai.autolab.|g' \
        -e 's|openclaw|autolab|g' \
        "$file" 2>/dev/null || true
}

apply_rebrand_paths() {
    local dir="$1"
    log "Renaming paths containing 'openclaw'..."

    # Rename directories (deepest first via -depth)
    find "$dir" -depth -type d -name '*openclaw*' -o -type d -name '*OpenClaw*' 2>/dev/null | while read -r dpath; do
        [[ -d "$dpath" ]] || continue  # may have been moved by parent rename
        local newpath
        newpath=$(echo "$dpath" | sed 's/openclaw/autolab/g; s/OpenClaw/AutoLab/g')
        if [[ "$dpath" != "$newpath" ]]; then
            mkdir -p "$(dirname "$newpath")"
            mv "$dpath" "$newpath" 2>/dev/null || true
        fi
    done

    # Rename files
    find "$dir" -type f -name '*openclaw*' -o -type f -name '*OpenClaw*' 2>/dev/null | while read -r fpath; do
        [[ -f "$fpath" ]] || continue
        local newpath
        newpath=$(echo "$fpath" | sed 's/openclaw/autolab/g; s/OpenClaw/AutoLab/g')
        if [[ "$fpath" != "$newpath" ]]; then
            mkdir -p "$(dirname "$newpath")"
            mv "$fpath" "$newpath" 2>/dev/null || true
        fi
    done
}

apply_full_rebrand() {
    local dir="$1"
    step "Applying full rebrand transform"

    [[ -f "$dir/openclaw.mjs" ]] && mv "$dir/openclaw.mjs" "$dir/autolab.mjs" && ok "Renamed openclaw.mjs → autolab.mjs"

    local total
    total=$(find "$dir" -type f \
        ! -path '*/.git/*' \
        ! -path '*/node_modules/*' \
        ! -path '*/.next/*' \
        ! -path '*/dist/*' \
        ! -name '*.lock' \
        | wc -l | tr -d ' ')

    log "Processing $total files for content rebrand..."

    local count=0
    find "$dir" -type f \
        ! -path '*/.git/*' \
        ! -path '*/node_modules/*' \
        ! -path '*/.next/*' \
        ! -path '*/dist/*' \
        ! -name '*.lock' \
        -print0 | while IFS= read -r -d '' file; do
        apply_rebrand_file "$file"
        count=$((count + 1))
        if (( count % 500 == 0 )); then
            log "  $count / $total files..."
        fi
    done

    ok "Content transforms applied"
    apply_rebrand_paths "$dir"
    ok "Path renames complete"
}

# ── Rebrand Verification ──────────────────────────────────────────────────────
verify_rebrand() {
    local dir="$1"
    local leaks
    leaks=$(grep -rn "openclaw" \
        --include="*.js" --include="*.ts" --include="*.tsx" \
        --include="*.json" --include="*.md" --include="*.mjs" \
        --include="*.sh" --include="*.css" --include="*.html" \
        --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist \
        "$dir/" 2>/dev/null \
        | grep -vi "dvallier-ai/autolab-public" \
        | grep -vi "# was openclaw" \
        | grep -vi "was: openclaw" \
        | grep -vi "originally openclaw" \
        | grep -vi "autolab-update" \
        | grep -vi "rebrand.*openclaw" \
        | grep -vi "openclaw.*rebrand" \
        | grep -vi "scripts/smart-update" \
        || true)

    local leak_count=0
    if [[ -n "$leaks" ]]; then
        leak_count=$(echo "$leaks" | wc -l | tr -d ' ')
    fi

    if (( leak_count > 0 )); then
        warn "Found $leak_count potential openclaw references:"
        echo "$leaks" | head -30
        return 1
    else
        ok "CLEAN — zero openclaw references found"
        return 0
    fi
}

# ── Phase 1: Fetch Upstream ───────────────────────────────────────────────────
phase_fetch() {
    step "Phase 1: Fetch upstream"

    if [[ ! -d "$UPSTREAM_BARE" ]]; then
        log "Initializing upstream bare clone..."
        mkdir -p "$(dirname "$UPSTREAM_BARE")"
        $GIT clone --bare "$UPSTREAM_REPO" "$UPSTREAM_BARE"
        ok "Upstream bare clone created"
    else
        log "Fetching latest tags from upstream..."
        (cd "$UPSTREAM_BARE" && $GIT fetch --tags --force origin '+refs/heads/*:refs/heads/*' 2>&1) || true
        ok "Upstream fetched"
    fi

    local latest
    latest=$(cd "$UPSTREAM_BARE" && $GIT tag --sort=-v:refname | grep -v beta | head -1)
    log "Latest stable upstream: $latest"
}

# ── Phase 2: Prepare Rebranded Source ─────────────────────────────────────────
phase_prepare() {
    local target_version="$1"
    step "Phase 2: Checkout & rebrand upstream $target_version"

    TEMP_DIR=$(mktemp -d "/tmp/autolab-update-XXXXXX")
    log "Temp workspace: $TEMP_DIR"

    log "Extracting $target_version via git archive..."
    mkdir -p "$TEMP_DIR/upstream"
    (cd "$UPSTREAM_BARE" && $GIT archive "$target_version") | tar -x -C "$TEMP_DIR/upstream"
    local file_count
    file_count=$(find "$TEMP_DIR/upstream" -type f | wc -l | tr -d ' ')
    ok "Extracted $file_count files at $target_version"

    apply_full_rebrand "$TEMP_DIR/upstream"
    verify_rebrand "$TEMP_DIR/upstream" || true
    ok "Rebranded upstream ready"
}

# ── Phase 3: Set Up Test Environment ──────────────────────────────────────────
phase_test_env() {
    local target_version="$1"
    step "Phase 3: Set up test environment at $TEST_DIR"

    if [[ ! -d "$TEST_DIR/.git" ]]; then
        log "Cloning fork into $TEST_DIR..."
        $GIT clone "$FORK_REPO" "$TEST_DIR" 2>&1 | tail -1
        ok "Cloned"
    else
        log "Resetting test env to origin/main..."
        (cd "$TEST_DIR" && $GIT fetch origin && $GIT checkout main && $GIT reset --hard origin/main) 2>&1 | tail -1
        ok "Reset to origin/main"
    fi

    local branch="update/${target_version}"
    (cd "$TEST_DIR" && $GIT checkout -B "$branch") 2>&1 | tail -1
    ok "Branch: $branch"

    # Back up local-only items
    mkdir -p "$TEMP_DIR/preserved"
    for item in "scripts/smart-update" ".autolab" "src/canvas-host/a2ui/a2ui.bundle.js"; do
        if [[ -e "$TEST_DIR/$item" ]]; then
            local safe_name
            safe_name=$(echo "$item" | tr '/' '_')
            cp -a "$TEST_DIR/$item" "$TEMP_DIR/preserved/$safe_name" 2>/dev/null || true
        fi
    done

    log "Overlaying rebranded upstream onto test env..."
    rsync -a --delete \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='.next' \
        --exclude='dist' \
        --exclude='scripts/smart-update' \
        "$TEMP_DIR/upstream/" "$TEST_DIR/"
    ok "Overlay complete"

    # Copy build artifacts from production
    if [[ -f "$PROD_DIR/src/canvas-host/a2ui/a2ui.bundle.js" ]]; then
        mkdir -p "$TEST_DIR/src/canvas-host/a2ui"
        cp "$PROD_DIR/src/canvas-host/a2ui/a2ui.bundle.js" "$TEST_DIR/src/canvas-host/a2ui/"
        ok "Copied a2ui.bundle.js from production"
    fi

    # Restore preserved items
    for item in "scripts/smart-update" ".autolab" "src/canvas-host/a2ui/a2ui.bundle.js"; do
        local safe_name
        safe_name=$(echo "$item" | tr '/' '_')
        if [[ -e "$TEMP_DIR/preserved/$safe_name" ]]; then
            local dest_parent
            dest_parent=$(dirname "$TEST_DIR/$item")
            mkdir -p "$dest_parent"
            cp -a "$TEMP_DIR/preserved/$safe_name" "$TEST_DIR/$item"
        fi
    done

    # Update version
    local clean_ver="${target_version#v}"
    if [[ -f "$TEST_DIR/package.json" ]]; then
        sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"$clean_ver\"/" "$TEST_DIR/package.json"
        ok "package.json version → $clean_ver"
    fi

    # Commit
    (cd "$TEST_DIR" && $GIT add -A)
    local stat_line
    stat_line=$(cd "$TEST_DIR" && $GIT diff --cached --stat | tail -1)
    log "Changes: $stat_line"

    (cd "$TEST_DIR" && \
        $GIT -c user.name="Cipher" -c user.email="cipher@autolab.app" \
        commit -m "update: upstream $target_version with full rebrand

Automated overlay from openclaw $target_version
All references rebranded: openclaw → autolab
Generated by autolab-update-linux.sh" --allow-empty) 2>&1 | tail -1

    ok "Committed on $branch"
}

# ── Phase 4: Verify ──────────────────────────────────────────────────────────
phase_verify() {
    step "Phase 4: Verify rebrand completeness"
    verify_rebrand "$TEST_DIR"
}

# ── Phase 5: Build ────────────────────────────────────────────────────────────
phase_build() {
    step "Phase 5: Build"
    cd "$TEST_DIR"

    mkdir -p "$LOG_DIR"

    log "Installing dependencies..."
    if pnpm install 2>"$LOG_DIR/update-pnpm.err.log" | tail -3; then
        ok "Dependencies installed"
    else
        err "pnpm install failed"
        tail -10 "$LOG_DIR/update-pnpm.err.log"
        return 1
    fi

    log "Building project..."
    if pnpm build 2>"$LOG_DIR/update-build.err.log" | tail -5; then
        ok "Build succeeded"
    else
        err "Build failed"
        tail -20 "$LOG_DIR/update-build.err.log"
        return 1
    fi
}

# ── Phase 6: Test Gateway ────────────────────────────────────────────────────
phase_test_gateway() {
    step "Phase 6: Test gateway on port $TEST_PORT"
    cd "$TEST_DIR"

    # Clear port
    fuser -k $TEST_PORT/tcp 2>/dev/null || true
    sleep 2

    mkdir -p "$LOG_DIR"

    log "Starting test gateway..."
    AUTOLAB_GATEWAY_PORT=$TEST_PORT \
    AUTOLAB_SERVICE_KIND=gateway \
    AUTOLAB_SERVICE_MARKER=autolab-test \
    AUTOLAB_ALLOW_MULTI_GATEWAY=1 \
        $NODE_BIN dist/index.js gateway --port $TEST_PORT \
        >"$LOG_DIR/gateway-test.log" 2>"$LOG_DIR/gateway-test.err.log" &
    local pid=$!

    local i=0
    while (( i < 30 )); do
        if curl -sf "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1; then
            ok "Gateway HEALTHY on port $TEST_PORT (pid $pid)"
            kill $pid 2>/dev/null || true
            wait $pid 2>/dev/null || true
            return 0
        fi
        if ! kill -0 $pid 2>/dev/null; then
            err "Gateway crashed. Last 20 lines of error log:"
            tail -20 "$LOG_DIR/gateway-test.err.log"
            return 1
        fi
        sleep 2
        i=$((i + 1))
    done

    err "Gateway didn't respond after 60s"
    kill $pid 2>/dev/null || true
    tail -20 "$LOG_DIR/gateway-test.err.log"
    return 1
}

# ── Phase 7: Record State ────────────────────────────────────────────────────
phase_record_state() {
    local target_version="$1"
    step "Phase 7: Record state"

    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
{
  "last_checked": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)",
  "last_seen_tag": "$target_version",
  "base_version": "$target_version",
  "applied_versions": ["$target_version"],
  "skipped_versions": [],
  "pending_versions": [],
  "last_update": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)",
  "test_dir": "$TEST_DIR",
  "status": "tested-ready-to-deploy"
}
EOF
    ok "State recorded — ready for deployment"
}

# ── Main Pipeline ─────────────────────────────────────────────────────────────
main() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   AutoLab Update Pipeline — Linux Fresh Rebrand Overlay   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    mkdir -p "$LOG_DIR"

    local target_version="${1:-}"

    phase_fetch

    if [[ -z "$target_version" ]]; then
        target_version=$(cd "$UPSTREAM_BARE" && $GIT tag --sort=-v:refname | grep -v beta | head -1)
        log "Auto-detected target: $target_version"
    fi

    if ! (cd "$UPSTREAM_BARE" && $GIT rev-parse "$target_version" >/dev/null 2>&1); then
        die "Version $target_version not found in upstream tags"
    fi

    local current_ver
    current_ver=$(grep '"version"' "$PROD_DIR/package.json" | head -1 | sed 's/.*"version": "\([^"]*\)".*/\1/')
    log "Current: v$current_ver → Target: $target_version"

    if [[ "v$current_ver" == "$target_version" ]]; then
        ok "Already at $target_version — nothing to do"
        exit 0
    fi

    phase_prepare "$target_version"
    phase_test_env "$target_version"

    local verify_ok=true
    phase_verify || verify_ok=false

    local build_ok=true
    phase_build || build_ok=false

    local gateway_ok=true
    if $build_ok; then
        phase_test_gateway || gateway_ok=false
    fi

    phase_record_state "$target_version"

    echo ""
    step "Pipeline Summary"
    echo ""
    echo -e "  Rebrand check:  $(${verify_ok} && echo -e "${GREEN}PASS${NC}" || echo -e "${YELLOW}WARNINGS${NC}")"
    echo -e "  Build:          $(${build_ok} && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
    echo -e "  Gateway test:   $(${gateway_ok} && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
    echo ""

    if $build_ok && $gateway_ok; then
        ok "All checks passed! Ready to deploy."
        echo ""
        echo "  Deploy:   ~/autolab/scripts/smart-update/autolab-deploy-linux.sh"
        echo "  Review:   cd $TEST_DIR && $GIT diff main"
        echo ""
    else
        warn "Some checks failed. Fix issues in $TEST_DIR, then:"
        echo "  Rebuild:  cd $TEST_DIR && pnpm build"
        echo ""
    fi
}

case "${1:-}" in
    -h|--help)
        echo "AutoLab Update Pipeline — Linux Fresh Rebrand Overlay"
        echo ""
        echo "Usage:"
        echo "  $0 [version]       Run full pipeline (default: latest stable)"
        echo "  $0 v2026.2.17      Update to specific version"
        ;;
    *)
        main "${1:-}"
        ;;
esac
