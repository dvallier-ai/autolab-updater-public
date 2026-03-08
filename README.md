# AutoLab Smart Update Pipeline

<p align="center">
  <a href="https://github.com/dvallier-ai/autolab-updater-public/releases"><img src="https://img.shields.io/github/v/release/dvallier-ai/autolab-updater-public?style=for-the-badge" alt="GitHub release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
</p>

**Automated upstream sync + rebrand for AutoLab forks**

Keep your [AutoLab](https://github.com/dvallier-ai/autolab-public) fork in sync with upstream OpenClaw releases while maintaining a complete rebrand.

## Overview

This pipeline keeps AutoLab up-to-date with upstream OpenClaw releases while
maintaining a complete rebrand (zero `openclaw` references in source).

**Strategy: "Fresh Rebrand Overlay"** — instead of patching diffs onto an already-rebranded codebase (which causes merge conflicts), we extract the upstream source at the target version, apply a full rebrand transform, and overlay it onto a test clone of our fork. Clean, deterministic, zero conflicts.

## Quick Start

```bash
# Update to latest upstream version (builds & tests in ~/autolab-test/)
./autolab-update.sh

# Update to a specific version
./autolab-update.sh v2026.2.15

# Deploy tested update to production (restarts gateway)
./autolab-deploy.sh

# Deploy without prompts (for automation)
./autolab-deploy.sh --yes

# Rollback if something breaks
./autolab-deploy.sh --rollback

# Just push to GitHub (skip local deploy)
./autolab-deploy.sh --push-only

# Check for new upstream versions (no changes made)
./autolab-cron-check.sh
```

## Scripts

| Script | Purpose | Safe to automate? |
|--------|---------|-------------------|
| `autolab-update.sh` | Fetch upstream, rebrand, build & test in ~/autolab-test/ | Yes |
| `autolab-deploy.sh` | Deploy from test → production, restart gateway | Yes (with `--yes`) |
| `autolab-cron-check.sh` | Check for new versions, optionally auto-update | Yes |
| `autolab-pull.sh` | For secondary machines: pull from fork & restart | Yes (with `--yes`) |
| `patcher.sh` | Legacy patch-based approach (kept for reference) | No |
| `orchestrate.sh` | Legacy orchestrator (kept for reference) | No |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Update Pipeline                          │
│                                                             │
│  1. FETCH         ~/.autolab/updates/upstream.git           │
│     └─ bare clone of github.com/openclaw/openclaw           │
│                                                             │
│  2. EXTRACT       /tmp/autolab-update-XXXXXX/               │
│     └─ git archive → temp dir                              │
│                                                             │
│  3. REBRAND       (in temp dir)                             │
│     ├─ sed transforms on all text files                     │
│     ├─ rename dirs/files with openclaw in path              │
│     └─ verify zero leaks                                   │
│                                                             │
│  4. OVERLAY       ~/autolab-test/                           │
│     ├─ clone from your-username/autolab fork                   │
│     ├─ rsync rebranded upstream over it                     │
│     ├─ preserve: scripts/smart-update, a2ui.bundle.js      │
│     └─ commit on branch update/vX.X.X                      │
│                                                             │
│  5. BUILD & TEST  (in ~/autolab-test/)                      │
│     ├─ pnpm install && pnpm build                          │
│     └─ start gateway on port 18792, health check           │
│                                                             │
│  6. DEPLOY        ~/autolab/                                │
│     ├─ backup (git ref + key files)                         │
│     ├─ rsync test → production                             │
│     ├─ rebuild, restart LaunchAgent                         │
│     ├─ health check (60s timeout)                           │
│     └─ auto-rollback if unhealthy                          │
│                                                             │
│  7. DISTRIBUTE    git push → your-username/autolab             │
│     └─ other machines: git pull && pnpm build              │
└─────────────────────────────────────────────────────────────┘
```

## Network Architecture

| Machine | Role | Gateway Install | Update Method |
|---------|------|-----------------|---------------|
| **mac-primary** | Primary | Git repo `~/autolab/` | `autolab-update.sh` + `autolab-deploy.sh` |
| **mac-secondary** | Secondary | npm global `/opt/homebrew/lib/node_modules/openclaw/` | `autolab-pull.sh` (converts to git-based) |
| **linux-machine** | Secondary | TBD | `autolab-pull.sh` |

### MacA Special Notes
- Currently running OpenClaw v2026.2.13 from **npm global install** (not git)
- LaunchAgent label: `ai.openclaw.gateway` (not rebranded)
- Gateway port: 18789
- First deployment will need to:
  1. Clone `your-username/autolab` to `~/autolab/`
  2. Replace the LaunchAgent plist (rename to `ai.autolab.gateway`)
  3. Update env vars from `OPENCLAW_*` to `AUTOLAB_*`

## Cron/Automation Setup

### Option 1: Cron Job (check daily, notify only)
```bash
# Add to crontab: crontab -e
# Check for updates at 6 AM daily, log results
0 6 * * * /Users/dan/autolab/scripts/smart-update/autolab-cron-check.sh >> /Users/dan/.autolab/logs/cron-check.log 2>&1
```

### Option 2: Cron Job (auto-update + deploy)
```bash
# Check and auto-deploy at 4 AM on Sundays
0 4 * * 0 /Users/dan/autolab/scripts/smart-update/autolab-cron-check.sh --auto-deploy >> /Users/dan/.autolab/logs/cron-check.log 2>&1
```

### Option 3: Agent Heartbeat
Add to your agent's `HEARTBEAT.md`:
```markdown
- [ ] Run `~/autolab/scripts/smart-update/autolab-cron-check.sh` periodically (1x/day)
- [ ] If new version found, notify Dan and optionally run update pipeline
```

### Option 4: Launchd Periodic (macOS native)
See `autolab-cron-check.sh --install-launchd` to install a daily LaunchAgent.

## Rebrand Transform Rules

Applied to all text files in the upstream source:

| Pattern | Replacement | Notes |
|---------|-------------|-------|
| `openclaw/openclaw` | `your-username/autolab` | GitHub org/repo |
| `@openclaw/openclaw` | `@your-username/autolab` | npm package |
| `OpenClaw` | `AutoLab` | Title case |
| `OPENCLAW` | `AUTOLAB` | Upper case |
| `openclaw.com` | `autolab.app` | Domain |
| `openclaw://` | `autolab://` | URL scheme |
| `.openclaw/` | `.autolab/` | Config dir |
| `openclaw-gateway` | `autolab-gateway` | Service name |
| `openclaw <cmd>` | `autolab <cmd>` | CLI commands |
| `openclaw` (catch-all) | `autolab` | Remaining refs |

**Known exceptions** (not renamed): Internal A2UI protocol CSS variables and JS API names in the pre-built `a2ui.bundle.js` (~18 references). These are internal protocol identifiers shared with native apps and cannot be renamed without breaking compatibility.

## State Files

| File | Purpose |
|------|---------|
| `~/.autolab/updates/state.json` | Current version, pending versions, last check |
| `~/.autolab/updates/upstream.git` | Bare clone of upstream repo |
| `~/.autolab/backups/latest` | Symlink to most recent backup |
| `~/.autolab/do-not-retry` | Flag set after failed rollback — must be manually removed |
| `~/.autolab/logs/` | Build, deploy, gateway logs |

## Troubleshooting

### Build fails: "A2UI sources missing"
The `a2ui.bundle.js` is a pre-built asset not in git. The update script copies it from production. If missing:
```bash
cp ~/autolab/src/canvas-host/a2ui/a2ui.bundle.js ~/autolab-test/src/canvas-host/a2ui/
```

### Push fails: "workflow scope required"
GitHub PAT doesn't have `workflow` scope. We exclude `.github/workflows/` from deployment. If upstream adds new workflows and they sneak in:
```bash
cd ~/autolab && /usr/bin/git rm -r .github/workflows/ && /usr/bin/git commit --no-verify -m "chore: remove upstream CI workflows"
```

### Gateway won't start in test: "already running"
The production gateway holds a lock. Test gateway uses `AUTOLAB_ALLOW_MULTI_GATEWAY=1` to bypass.

### Pre-commit hook fails: "mapfile: command not found"
The hook uses bash 4+ features. Deploy uses `--no-verify` to skip it.

### DO-NOT-RETRY flag set
A previous deploy failed and rolled back. Investigate the issue, then:
```bash
rm ~/.autolab/do-not-retry
```

### Git guard blocks operations
`~/.local/bin/git` intercepts openclaw-related git operations. Use `/usr/bin/git` directly or work in `~/autolab-test/` (not guarded).
