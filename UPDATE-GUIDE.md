# AutoLab Update Guide

> How to update AutoLab from upstream OpenClaw on all machines.

## Overview

AutoLab is a rebrand of [OpenClaw](https://github.com/openclaw/openclaw). Updates are pulled from upstream, rebranded (all `openclaw` → `autolab` references), tested, and deployed.

**Strategy: "Fresh Rebrand Overlay"** — extract upstream source at target version, apply full rebrand transform, overlay onto our fork, build, test gateway, deploy. Zero merge conflicts.

## Machines

| Machine | OS | Agent | Gateway Port | Update Script | Service Manager |
|---------|-----|-------|-------------|---------------|-----------------|
| **linux-machine** | Linux (Ubuntu 25.10) | Agent-C | 18789 | `autolab-update-linux.sh` | systemd (`autolab-gateway.service`) |
| **mac-primary** | macOS | Agent-A | 18789 | `autolab-update.sh` | launchctl (`ai.autolab.gateway`) |
| **mac-secondary** | macOS | Agent-B | 18789 | `autolab-update.sh` | launchctl (`ai.autolab.gateway`) |

> **Note:** MacA user is UID **502** (not 501). Always use `$(id -u)` in launchctl commands.

## Quick Start

### Check for updates (any machine)
```bash
cd ~/autolab/scripts/smart-update
./autolab-cron-check.sh
```

### Linux (Agent-C — linux-machine)
```bash
cd ~/autolab/scripts/smart-update

# 1. Update (fetch, rebrand, build, test on port 18793)
./autolab-update-linux.sh              # latest version
./autolab-update-linux.sh v2026.2.17   # specific version

# 2. Deploy (backup, sync, rebuild, restart systemd, health check)
./autolab-deploy-linux.sh              # interactive
./autolab-deploy-linux.sh --yes        # auto-approve

# 3. Rollback if broken
./autolab-deploy-linux.sh --rollback
```

### macOS (Liam, Nova — MacB, MacA)
```bash
cd ~/autolab/scripts/smart-update

# 1. Update (fetch, rebrand, build, test on port 18793)
PATH=/opt/homebrew/bin:$PATH ./autolab-update.sh              # latest
PATH=/opt/homebrew/bin:$PATH ./autolab-update.sh v2026.2.17   # specific

# 2. Deploy (backup, sync, rebuild, restart launchctl, health check)
PATH=/opt/homebrew/bin:$PATH ./autolab-deploy.sh              # interactive
PATH=/opt/homebrew/bin:$PATH ./autolab-deploy.sh --yes        # auto-approve

# 3. Rollback if broken
PATH=/opt/homebrew/bin:$PATH ./autolab-deploy.sh --rollback
```

> **Important:** macOS SSH sessions don't include `/opt/homebrew/bin` in PATH. Always prefix with `PATH=/opt/homebrew/bin:$PATH` when running via SSH.

## What the Scripts Do

### Update Script (`autolab-update*.sh`)
1. **Fetch** — Clone/update bare upstream repo at `~/.autolab/updates/upstream.git`
2. **Extract** — `git archive` target version into temp dir
3. **Rebrand** — sed transforms on all text files + rename dirs/files containing `openclaw`
4. **Overlay** — Clone our fork into `~/autolab-test/`, rsync rebranded source over it
5. **Build** — `pnpm install && pnpm build` in test dir
6. **Test** — Start gateway on alternate port (18793), verify `/health` endpoint
7. **Record** — Write state to `~/.autolab/updates/state.json`

### Deploy Script (`autolab-deploy*.sh`)
1. **Preflight** — Verify test env exists and is built
2. **Backup** — Save git ref + key files to `~/.autolab/backups/`
3. **Sync** — rsync from `~/autolab-test/` → `~/autolab/` (excludes .git, node_modules, scripts/smart-update)
4. **Build** — `pnpm install && pnpm build` in production
5. **Restart** — systemd (`systemctl --user restart`) or launchctl (`bootout` + `bootstrap`)
6. **Health check** — Poll `/health` for 60s
7. **Auto-rollback** — If unhealthy, revert to backup git ref and rebuild
8. **Push** — Push to `dvallier-ai/autolab-public` on GitHub

## Key Differences: Linux vs macOS

| Feature | Linux | macOS |
|---------|-------|-------|
| `sed` in-place | `sed -i` | `sed -i ''` |
| Service manager | `systemctl --user` | `launchctl gui/$(id -u)` |
| Node location | `/usr/bin/node` | `/opt/homebrew/bin/node` |
| Service file | `~/.config/systemd/user/autolab-gateway.service` | `~/Library/LaunchAgents/ai.autolab.gateway.plist` |
| PATH in SSH | Usually fine | Needs `/opt/homebrew/bin` explicitly |

## Remote Update (via SSH from Cipher)

Cipher can update any machine remotely:

```bash
# Update Liam (MacB)
ssh user@machine-1 "cd ~/autolab/scripts/smart-update && PATH=/opt/homebrew/bin:\$PATH bash autolab-update.sh v2026.2.17"
ssh user@machine-1 "cd ~/autolab/scripts/smart-update && PATH=/opt/homebrew/bin:\$PATH bash autolab-deploy.sh --yes"

# Update Nova (MacA)
ssh user@machine-2 "cd ~/autolab/scripts/smart-update && PATH=/opt/homebrew/bin:\$PATH bash autolab-update.sh v2026.2.17"
ssh user@machine-2 "cd ~/autolab/scripts/smart-update && PATH=/opt/homebrew/bin:\$PATH bash autolab-deploy.sh --yes"
```

## Known Gotchas

### 1. `a2ui.bundle.js` is pre-built
Not in git. The update script copies it from production. If missing on a fresh clone:
```bash
# From existing install:
cp ~/autolab/src/canvas-host/a2ui/a2ui.bundle.js ~/autolab-test/src/canvas-host/a2ui/
# Or from npm install (macOS):
cp /opt/homebrew/lib/node_modules/openclaw/dist/canvas-host/a2ui/a2ui.bundle.js ~/autolab/src/canvas-host/a2ui/
```

### 2. GitHub rejects workflow pushes
The PAT doesn't have `workflow` scope. Deploy script auto-removes `.github/workflows/` before pushing.

### 3. Config keys change between versions
Newer versions may add config keys that older versions reject as "unrecognized". This causes crash loops on rollback. If gateway won't start after rollback, check `~/.autolab/autolab.json` for unknown keys.

### 4. Rebrand "leaks" in a2ui.bundle.js are expected
The pre-built `a2ui.bundle.js` contains ~18 `openclaw` references (CSS variables, JS API names). These are internal protocol identifiers shared with native apps and **cannot be renamed**.

### 5. DO-NOT-RETRY flag
After a failed rollback, `~/.autolab/do-not-retry` is created. Must be manually removed after investigating:
```bash
rm ~/.autolab/do-not-retry
```

### 6. Port configuration
All machines use port **18789**. The test gateway uses **18793**. Make sure `PROD_PORT` in scripts matches the actual service config.

### 7. Process title still shows `openclaw-gateway`
The compiled binary bakes in the process title. `autolab-gateway` shows on Linux (systemd names it), but macOS may show `openclaw-gateway` in `ps`. This is cosmetic.

## State Files

| File | Purpose |
|------|---------|
| `~/.autolab/updates/state.json` | Current version, last check, pending versions |
| `~/.autolab/updates/upstream.git` | Bare clone of upstream OpenClaw |
| `~/.autolab/backups/latest` | Symlink to most recent backup |
| `~/.autolab/do-not-retry` | Safety flag after failed rollback |
| `~/autolab-test/` | Test environment (persists between updates) |

## Rebrand Rules

All text files get these transforms (order matters — specific first, catch-all last):

| Pattern | Replacement |
|---------|-------------|
| `openclaw/openclaw` | `dvallier-ai/autolab-public` |
| `@openclaw/openclaw` | `@dvallier-ai/autolab-public` |
| `OpenClaw` | `AutoLab` |
| `OPENCLAW` | `AUTOLAB` |
| `openclaw.com` | `autolab.app` |
| `openclaw://` | `autolab://` |
| `.openclaw/` | `.autolab/` |
| `openclaw` (catch-all) | `autolab` |

Files/dirs with `openclaw` in their names are also renamed.

## First-Time Setup (New Machine)

If a machine doesn't have the git repo yet:

```bash
# 1. Clone
git clone https://github.com/dvallier-ai/autolab-public.git ~/autolab

# 2. Copy a2ui.bundle.js from an existing machine
scp <existing>:~/autolab/src/canvas-host/a2ui/a2ui.bundle.js ~/autolab/src/canvas-host/a2ui/

# 3. Install deps & build
cd ~/autolab && pnpm install && pnpm build

# 4. Copy/create config
# Either migrate from .openclaw or copy from another machine

# 5. Create service (systemd or launchctl) — see existing units as templates

# 6. Start gateway
```

---

*Last updated: 2026-02-17 by Cipher 🔐*
