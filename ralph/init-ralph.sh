#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking for CLI mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Run from project root: prd.json in ralph/, progress.txt in root.
if [[ "$SCRIPT_DIR" == *"/.cursor/ralph-scripts" ]]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  WORKSPACE_ROOT="$(pwd)"
fi
cd "$WORKSPACE_ROOT"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check for jq (required for prd.json)
if ! command -v jq &> /dev/null; then
  echo "⚠️  Warning: jq not found (required for PRD flow)."
  echo "   Install via: brew install jq  (macOS) or your package manager"
  echo ""
fi

# Check for cursor-agent CLI
if ! command -v cursor-agent &> /dev/null; then
  echo "⚠️  Warning: cursor-agent CLI not found."
  echo "   Install via: curl https://cursor.com/install -fsS | bash"
  echo ""
fi

# Create directories
mkdir -p .ralph
mkdir -p .cursor/ralph-scripts
mkdir -p tasks

# =============================================================================
# prd.json: CREATED VIA SKILLS (not by this script)
# =============================================================================
# Flow: 1) PRD skill (in Cursor) → creates tasks/prd-[feature-name].md
#       2) Ralph skill (in Cursor) → creates ralph/prd.json from that PRD
# The PRD skill asks clarifying questions and waits for your answers before
# writing the .md file. You run both skills manually in Cursor.
# =============================================================================

if [[ -f "ralph/prd.json" ]]; then
  echo "✓ ralph/prd.json already exists"
else
  echo "📋 ralph/prd.json not found (will be created via Cursor skills)"
  echo ""
  echo "   To create it, use this flow in Cursor:"
  echo "   1. PRD skill: ask to create a PRD (e.g. \"create a prd for [your feature]\")."
  echo "      The skill will ask you clarifying questions; after you answer, it will"
  echo "      create a file in tasks/ (e.g. tasks/prd-my-feature.md)."
  echo "   2. Ralph skill: with that PRD file, ask to convert it (e.g. \"convert this"
  echo "      prd to ralph format\" or \"create prd.json from this\"). It will create"
  echo "      ralph/prd.json."
  echo ""
fi

# =============================================================================
# CREATE progress.txt IN ROOT IF NOT EXISTS
# =============================================================================

if [[ ! -f "progress.txt" ]]; then
  echo "📝 Creating progress.txt..."
  echo "=== Ralph progress log ===" > progress.txt
  echo "   Agents will append entries here when they complete a User Story."
else
  echo "✓ progress.txt already exists"
fi

# =============================================================================
# INITIALIZE STATE FILES
# =============================================================================

echo "📁 Initializing .ralph/ directory..."

cat > .ralph/guardrails.md << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

cat > .ralph/progress.md << 'EOF'
# Progress Log

> Updated by the agent after significant work.

## Summary

- Iterations completed: 0
- Current status: Initialized

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is rotated (fresh agent), the new agent reads this file.
This is how Ralph maintains continuity across iterations.

## Session History

EOF

cat > .ralph/errors.log << 'EOF'
# Error Log

> Failures to review and use to update guardrails.

EOF

cat > .ralph/activity.log << 'EOF'
# Activity Log

> Activity log.

EOF

echo "0" > .ralph/.iteration

# =============================================================================
# INSTALL SCRIPTS
# =============================================================================

echo "📦 Installing scripts..."

# Copy scripts: prefer SKILL_DIR/scripts/ (legacy layout), else SCRIPT_DIR (ralph/ in this repo)
if [[ -d "$SKILL_DIR/scripts" ]] && compgen -G "$SKILL_DIR/scripts/"*.sh > /dev/null 2>&1; then
  cp "$SKILL_DIR/scripts/"*.sh .cursor/ralph-scripts/ 2>/dev/null || true
else
  cp "$SCRIPT_DIR/"*.sh .cursor/ralph-scripts/ 2>/dev/null || true
fi
chmod +x .cursor/ralph-scripts/*.sh 2>/dev/null || true

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  # Don't gitignore .ralph/ - we want it tracked for state persistence
  if ! grep -q "ralph-config.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API keys)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API keys)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph initialized!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files/dirs created:"
echo "  • tasks/              - Put PRD .md here (PRD skill creates e.g. tasks/prd-my-feature.md)"
echo "  • ralph/prd.json      - Created by Ralph skill from your PRD (not by this script)"
echo "  • progress.txt        - Progress log (agents append when completing a US)"
echo "  • .ralph/guardrails.md - Lessons learned (agent updates this)"
echo "  • .ralph/activity.log - Activity log"
echo "  • .ralph/errors.log   - Failure log"
echo ""
echo "Next steps:"
echo "  1. If you don't have ralph/prd.json yet: in Cursor use the PRD skill to create"
echo "     a PRD (tasks/prd-*.md), then the Ralph skill to create ralph/prd.json."
echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh  (or ralph-loop.sh)"
echo ""
echo "One agent runs per User Story; when done the agent outputs <ralph>US-DONE US-XXX</ralph>"
echo "and the script updates prd.json. progress.txt is appended by each agent."
echo "Monitor progress: tail -f .ralph/activity.log"
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "═══════════════════════════════════════════════════════════════════"