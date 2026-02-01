#!/bin/bash
# Ralph Wiggum (cursor-ralph-loop): One-click installer
# Variant: PRD from Cursor skills, one agent per User Story (prd.json).
#
# Usage: curl -fsSL https://raw.githubusercontent.com/peppescaffidi/cursor-ralph-loop/main/install.sh | bash

set -euo pipefail

# Repository: change if you use a fork
REPO_OWNER="${RALPH_REPO_OWNER:-peppescaffidi}"
REPO_NAME="${RALPH_REPO_NAME:-cursor-ralph-loop}"
REPO_BRANCH="${RALPH_REPO_BRANCH:-master}"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Installer (cursor-ralph-loop)"
echo "═══════════════════════════════════════════════════════════════════"
echo "   PRD-based flow: ralph/prd.json, one agent per User Story"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  echo "   Run: git init"
  echo ""
fi

# Check for jq (required for prd.json)
if ! command -v jq &> /dev/null; then
  echo "⚠️  jq not found (required for ralph/prd.json)."
  echo "   Install via: brew install jq  (macOS) or your package manager"
  echo ""
fi

# Check for cursor-agent CLI
if ! command -v cursor-agent &> /dev/null; then
  echo "⚠️  cursor-agent CLI not found."
  echo "   Install via: curl https://cursor.com/install -fsS | bash"
  echo ""
fi

# Check for gum and offer to install
if ! command -v gum &> /dev/null; then
  echo "📦 gum not found (provides beautiful CLI menus)"

  SHOULD_INSTALL=""
  if [[ "${INSTALL_GUM:-}" == "1" ]]; then
    SHOULD_INSTALL="y"
  else
    read -p "   Install gum? [y/N] " -n 1 -r < /dev/tty
    echo
    SHOULD_INSTALL="$REPLY"
  fi

  if [[ "$SHOULD_INSTALL" =~ ^[Yy]$ ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      if command -v brew &> /dev/null; then
        echo "   Installing via Homebrew..."
        brew install gum
      else
        echo "   ⚠️  Homebrew not found. Install manually: brew install gum"
      fi
    elif [[ -f /etc/debian_version ]]; then
      echo "   Installing via apt..."
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
      sudo apt update && sudo apt install -y gum
    elif [[ -f /etc/fedora-release ]] || [[ -f /etc/redhat-release ]]; then
      echo "   Installing via dnf..."
      echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo
      sudo dnf install -y gum
    else
      echo "   ⚠️  Unknown Linux distro. Install manually: https://github.com/charmbracelet/gum#installation"
    fi
  fi
  echo ""
fi

WORKSPACE_ROOT="$(pwd)"

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================

echo "📁 Creating directories..."
mkdir -p .cursor/ralph-scripts
mkdir -p .ralph
mkdir -p tasks
mkdir -p ralph

# =============================================================================
# DOWNLOAD SCRIPTS (from ralph/ in this repo)
# =============================================================================

echo "📥 Downloading Ralph scripts..."

SCRIPTS=(
  "ralph-common.sh"
  "ralph-setup.sh"
  "ralph-loop.sh"
  "ralph-once.sh"
  "ralph-parallel.sh"
  "ralph-retry.sh"
  "init-ralph.sh"
  "ralph.sh"
)

for script in "${SCRIPTS[@]}"; do
  if curl -fsSL "$REPO_RAW/ralph/$script" -o ".cursor/ralph-scripts/$script" 2>/dev/null; then
    chmod +x ".cursor/ralph-scripts/$script"
  else
    echo "   ⚠️  Could not download $script"
  fi
done

echo "✓ Scripts installed to .cursor/ralph-scripts/"

# =============================================================================
# INITIALIZE .ralph/ STATE
# =============================================================================

echo "📁 Initializing .ralph/ state directory..."

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

> Failures detected by stream-parser. Use to update guardrails.

EOF

cat > .ralph/activity.log << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF

echo "0" > .ralph/.iteration

echo "✓ .ralph/ initialized"

# =============================================================================
# CREATE progress.txt IN ROOT
# =============================================================================

if [[ ! -f "progress.txt" ]]; then
  echo "📝 Creating progress.txt..."
  echo "=== Ralph progress log ===" > progress.txt
  echo "   Agents will append entries here when they complete a User Story."
  echo "✓ Created progress.txt"
else
  echo "✓ progress.txt already exists"
fi

# =============================================================================
# prd.json: CREATED VIA CURSOR SKILLS (not by this script)
# =============================================================================

if [[ -f "ralph/prd.json" ]]; then
  echo "✓ ralph/prd.json already exists"
else
  echo "📋 ralph/prd.json not found (will be created via Cursor skills)"
  echo ""
  echo "   To create it:"
  echo "   1. PRD skill: ask Cursor to create a PRD (e.g. \"create a prd for [your feature]\")."
  echo "      The skill will ask clarifying questions, then create tasks/prd-my-feature.md"
  echo "   2. Ralph skill: with that file, ask \"convert this prd to ralph format\" or"
  echo "      \"create prd.json from this\". It will create ralph/prd.json."
  echo ""
fi

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  if ! grep -q "ralph-config.json" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API key)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  if ! grep -q "\.ralph/\.current_prompt" .gitignore 2>/dev/null; then
    echo ".ralph/.current_prompt" >> .gitignore
  fi
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API key)
.cursor/ralph-config.json
.ralph/.current_prompt
EOF
fi
echo "✓ Updated .gitignore"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph (cursor-ralph-loop) installed!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files/dirs created:"
echo ""
echo "  📁 .cursor/ralph-scripts/"
echo "     ├── ralph-setup.sh          - Main entry (interactive)"
echo "     ├── ralph-loop.sh           - CLI mode (scripting)"
echo "     ├── ralph-once.sh           - Single US (testing)"
echo "     └── ...                     - Other utilities"
echo ""
echo "  📁 .ralph/                     - State (guardrails, progress, logs)"
echo "  📁 tasks/                      - Put PRD .md here (PRD skill creates them)"
echo "  📁 ralph/                      - Put ralph/prd.json here (Ralph skill creates it)"
echo "  📄 progress.txt                - Progress log (agents append when completing a US)"
echo ""
echo "Next steps:"
echo "  1. Create ralph/prd.json via Cursor skills (PRD skill → tasks/prd-*.md, then Ralph skill → ralph/prd.json)"
echo "     Or create ralph/prd.json manually with project, userStories (id, title, acceptanceCriteria, passes)."
echo "  2. Run: ./.cursor/ralph-scripts/ralph-setup.sh"
echo ""
echo "Commands:"
echo "  ./.cursor/ralph-scripts/ralph-setup.sh   - Interactive setup + loop"
echo "  ./.cursor/ralph-scripts/ralph-once.sh     - Run single User Story (test)"
echo "  ./.cursor/ralph-scripts/ralph-loop.sh    - CLI (e.g. -n 50 -m opus-4.5-thinking --branch feature/foo --pr)"
echo ""
echo "Monitor: tail -f .ralph/activity.log"
echo ""
echo "Learn more: https://ghuntley.com/ralph/"
echo "This variant: PRD from skills, one agent per US, prd.json + progress.txt"
echo "═══════════════════════════════════════════════════════════════════"
