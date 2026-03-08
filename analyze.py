#!/usr/bin/env python3
"""
AutoLab Smart Update Analyzer
Parses openclaw changelogs and categorizes each entry by:
- Category: SECURITY, BUGFIX, FEATURE, PLATFORM, INTERNAL
- Relevance: HIGH (auto-apply), MEDIUM (review), LOW (skip candidate)
- Rebrand: whether entry references openclaw branding/paths that need transform
- Components: which parts of the system are affected

Outputs a structured analysis report for each release.
"""

import json
import re
import sys
import os
from datetime import datetime, timezone
from pathlib import Path

UPDATES_DIR = Path.home() / ".autolab" / "updates"
CHANGELOGS_DIR = UPDATES_DIR / "changelogs"
REPORTS_DIR = UPDATES_DIR / "reports"
STATE_FILE = UPDATES_DIR / "state.json"

# Platform/channel keywords - used to tag platform-specific changes
PLATFORMS = {
    "telegram": "telegram",
    "discord": "discord",
    "slack": "slack",
    "whatsapp": "whatsapp",
    "signal": "signal",
    "line": "line",
    "imessage": "imessage",
    "bluebubbles": "bluebubbles",
    "feishu": "feishu",
    "nostr": "nostr",
    "tlon": "tlon",
    "zalo": "zalo",
    "google chat": "google_chat",
    "twilio": "twilio",
    "telnyx": "telnyx",
    "voice call": "voice_call",
}

# Components we actively use (higher relevance)
ACTIVE_COMPONENTS = {
    "telegram",      # We use Telegram
    "gateway",       # Core gateway
    "agents",        # Agent system
    "cli",           # CLI tools
    "tui",           # Terminal UI
    "security",      # Security fixes
    "memory",        # Memory system
    "sandbox",       # Sandbox
    "cron",          # Cron jobs
    "plugins",       # Plugin system
    "sessions",      # Session management
    "models",        # Model management
    "media",         # Media handling
    "skills",        # Skills system
    "diagnostics",   # Diagnostics
}

# Security keywords
SECURITY_KEYWORDS = [
    r"\bsecurity\b", r"\bssrf\b", r"\bharden", r"\bpath.traversal",
    r"\binjection\b", r"\bbypass\b", r"\bvulnerab", r"\bcve\b",
    r"\bauth\w*\b", r"\bpermission", r"\baccess.control",
    r"\bdisclosure\b", r"\bescap[ei]", r"\bsanitiz", r"\breject\b.*\b(ambiguous|oversized|invalid)",
    r"\bblock\b.*\b(cross-origin|loopback|private)", r"\brequire\b.*\b(signature|verification|explicit)",
]

# Rebrand-sensitive patterns
REBRAND_PATTERNS = [
    r"`openclaw\b",
    r"openclaw\s+(message|doctor|dashboard|tui|gateway|reset|uninstall|security)",
    r"~/.openclaw/",
    r"openclaw://",
    r"OpenClaw\b",
    r"\.openclaw/",
]


def detect_section(line: str) -> str | None:
    """Detect changelog section headers."""
    line = line.strip().lower()
    if line.startswith("### changes") or line.startswith("### added"):
        return "changes"
    elif line.startswith("### fix") or line.startswith("### bug fix"):
        return "fixes"
    elif line.startswith("### security"):
        return "security"
    elif line.startswith("### breaking"):
        return "breaking"
    elif line.startswith("### deprecat"):
        return "deprecated"
    elif line.startswith("###"):
        return "other"
    return None


def parse_changelog(text: str) -> list[dict]:
    """Parse a changelog into structured entries."""
    entries = []
    current_section = "unknown"
    current_entry = ""

    for line in text.split("\n"):
        section = detect_section(line)
        if section:
            # Save previous entry
            if current_entry.strip():
                entries.append({"section": current_section, "text": current_entry.strip()})
            current_section = section
            current_entry = ""
            continue

        # New entry starts with "- "
        if line.strip().startswith("- "):
            if current_entry.strip():
                entries.append({"section": current_section, "text": current_entry.strip()})
            current_entry = line.strip()[2:]  # Remove leading "- "
        elif current_entry and line.strip():
            current_entry += " " + line.strip()

    # Last entry
    if current_entry.strip():
        entries.append({"section": current_section, "text": current_entry.strip()})

    return entries


def extract_pr_number(text: str) -> str | None:
    """Extract PR number from entry."""
    m = re.search(r"\(#(\d+)\)", text)
    return m.group(1) if m else None


def extract_component(text: str) -> list[str]:
    """Extract component tags from entry text."""
    components = []
    text_lower = text.lower()

    # Check prefix pattern like "CLI/Plugins:" or "Security/Memory:"
    prefix_match = re.match(r"^([\w/\-]+):", text)
    if prefix_match:
        prefix = prefix_match.group(1).lower()
        for part in prefix.split("/"):
            part = part.strip()
            if part in ACTIVE_COMPONENTS:
                components.append(part)
            # Map common prefixes
            elif part in ("agent", "agents"):
                components.append("agents")
            elif part in ("net", "gateway"):
                components.append("gateway")
            elif part == "qmd":
                components.append("memory")
            elif part in ("builtin",):
                components.append("memory")

    # Check for platform mentions
    for keyword, platform in PLATFORMS.items():
        if keyword in text_lower:
            components.append(platform)

    # Check for security context
    for pattern in SECURITY_KEYWORDS:
        if re.search(pattern, text_lower):
            if "security" not in components:
                components.append("security")
            break

    return list(set(components))


def categorize_entry(entry: dict) -> dict:
    """Categorize a changelog entry."""
    text = entry["text"]
    section = entry["section"]
    text_lower = text.lower()

    # Determine category
    if section == "security":
        category = "SECURITY"
    elif any(re.search(p, text_lower) for p in SECURITY_KEYWORDS):
        category = "SECURITY"
    elif section == "fixes":
        category = "BUGFIX"
    elif section == "changes":
        category = "FEATURE"
    elif section == "breaking":
        category = "BREAKING"
    elif section == "deprecated":
        category = "DEPRECATED"
    else:
        category = "OTHER"

    # Extract components
    components = extract_component(text)

    # Check if entry needs rebrand transform
    needs_rebrand = any(re.search(p, text, re.IGNORECASE) for p in REBRAND_PATTERNS)

    # Determine relevance
    if category == "SECURITY":
        relevance = "HIGH"
    elif category == "BREAKING":
        relevance = "HIGH"
    elif category == "BUGFIX" and any(c in ACTIVE_COMPONENTS for c in components):
        relevance = "HIGH"
    elif category == "FEATURE" and any(c in ACTIVE_COMPONENTS for c in components):
        relevance = "MEDIUM"
    elif category == "BUGFIX":
        relevance = "MEDIUM"
    elif any(c in PLATFORMS.values() for c in components) and not any(c in ACTIVE_COMPONENTS for c in components):
        relevance = "LOW"
    else:
        relevance = "MEDIUM"

    # Determine recommended action
    if relevance == "HIGH":
        action = "AUTO_APPLY"
    elif relevance == "MEDIUM":
        action = "REVIEW"
    else:
        action = "SKIP"

    return {
        "text": text,
        "section": section,
        "category": category,
        "relevance": relevance,
        "action": action,
        "needs_rebrand": needs_rebrand,
        "components": components,
        "pr": extract_pr_number(text),
    }


def analyze_release(tag: str) -> dict:
    """Analyze a single release changelog."""
    changelog_path = CHANGELOGS_DIR / f"{tag}.md"
    if not changelog_path.exists():
        return {"tag": tag, "error": "changelog not found", "entries": []}

    text = changelog_path.read_text()
    raw_entries = parse_changelog(text)
    analyzed = [categorize_entry(e) for e in raw_entries]

    # Summary stats
    summary = {
        "total": len(analyzed),
        "by_category": {},
        "by_relevance": {},
        "by_action": {},
        "security_count": 0,
        "needs_rebrand_count": 0,
        "active_component_count": 0,
    }

    for e in analyzed:
        summary["by_category"][e["category"]] = summary["by_category"].get(e["category"], 0) + 1
        summary["by_relevance"][e["relevance"]] = summary["by_relevance"].get(e["relevance"], 0) + 1
        summary["by_action"][e["action"]] = summary["by_action"].get(e["action"], 0) + 1
        if e["category"] == "SECURITY":
            summary["security_count"] += 1
        if e["needs_rebrand"]:
            summary["needs_rebrand_count"] += 1
        if any(c in ACTIVE_COMPONENTS for c in e["components"]):
            summary["active_component_count"] += 1

    return {
        "tag": tag,
        "analyzed_at": datetime.now(timezone.utc).isoformat(),
        "summary": summary,
        "entries": analyzed,
    }


def generate_report(analysis: dict) -> str:
    """Generate a human-readable analysis report."""
    tag = analysis["tag"]
    s = analysis["summary"]
    entries = analysis["entries"]

    lines = [
        f"# Update Analysis: {tag}",
        f"Analyzed: {analysis['analyzed_at']}",
        f"Total entries: {s['total']}",
        "",
        "## Summary",
        f"- Security fixes: {s['security_count']}",
        f"- Needs rebrand transform: {s['needs_rebrand_count']}",
        f"- Affects active components: {s['active_component_count']}",
        "",
        "### By Action",
    ]
    for action, count in sorted(s["by_action"].items()):
        lines.append(f"  - {action}: {count}")

    lines.extend(["", "### By Category"])
    for cat, count in sorted(s["by_category"].items()):
        lines.append(f"  - {cat}: {count}")

    # List HIGH relevance entries
    high = [e for e in entries if e["relevance"] == "HIGH"]
    if high:
        lines.extend(["", "## AUTO_APPLY (High Relevance)", ""])
        for e in high:
            pr = f" (#{e['pr']})" if e['pr'] else ""
            rebrand = " [REBRAND]" if e['needs_rebrand'] else ""
            comps = ", ".join(e['components']) if e['components'] else "general"
            lines.append(f"- [{e['category']}] [{comps}]{rebrand}{pr}: {e['text'][:120]}...")

    # List MEDIUM relevance entries
    medium = [e for e in entries if e["relevance"] == "MEDIUM"]
    if medium:
        lines.extend(["", "## REVIEW (Medium Relevance)", ""])
        for e in medium:
            pr = f" (#{e['pr']})" if e['pr'] else ""
            rebrand = " [REBRAND]" if e['needs_rebrand'] else ""
            comps = ", ".join(e['components']) if e['components'] else "general"
            lines.append(f"- [{e['category']}] [{comps}]{rebrand}{pr}: {e['text'][:120]}...")

    # List LOW relevance entries
    low = [e for e in entries if e["relevance"] == "LOW"]
    if low:
        lines.extend(["", "## SKIP (Low Relevance)", ""])
        for e in low:
            pr = f" (#{e['pr']})" if e['pr'] else ""
            comps = ", ".join(e['components']) if e['components'] else "general"
            lines.append(f"- [{e['category']}] [{comps}]{pr}: {e['text'][:100]}...")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        # Analyze all pending versions from state
        if STATE_FILE.exists():
            state = json.loads(STATE_FILE.read_text())
            tags = state.get("pending_versions", [])
        else:
            print("No state file found. Run monitor.sh first.", file=sys.stderr)
            sys.exit(1)
    elif sys.argv[1] == "--all":
        # Analyze all cached changelogs
        tags = sorted([f.stem for f in CHANGELOGS_DIR.glob("v*.md")])
    else:
        tags = sys.argv[1:]

    if not tags:
        print("No versions to analyze.", file=sys.stderr)
        print(json.dumps({"status": "nothing_to_analyze", "analyses": []}))
        sys.exit(0)

    print(f"Analyzing {len(tags)} release(s)...", file=sys.stderr)

    all_analyses = []
    for tag in tags:
        print(f"  Analyzing {tag}...", file=sys.stderr)
        analysis = analyze_release(tag)
        all_analyses.append(analysis)

        # Save report
        report = generate_report(analysis)
        report_path = REPORTS_DIR / f"{tag}-analysis.md"
        report_path.write_text(report)
        print(f"    Report saved: {report_path}", file=sys.stderr)

        # Save JSON analysis
        json_path = REPORTS_DIR / f"{tag}-analysis.json"
        json_path.write_text(json.dumps(analysis, indent=2))

    # Output combined result
    result = {
        "status": "analyzed",
        "count": len(all_analyses),
        "analyses": [
            {
                "tag": a["tag"],
                "summary": a["summary"],
                "high_count": sum(1 for e in a["entries"] if e["relevance"] == "HIGH"),
                "needs_rebrand": a["summary"]["needs_rebrand_count"],
            }
            for a in all_analyses
        ],
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
