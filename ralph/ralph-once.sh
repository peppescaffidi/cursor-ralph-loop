#!/bin/bash
# Ralph Wiggum: Single Iteration (Human-in-the-Loop)
#
# Runs exactly ONE iteration of the Ralph loop, then stops.
# Useful for testing your task definition before going AFK.
#
# Usage:
#   ./ralph-once.sh                    # Run single iteration
#   ./ralph-once.sh /path/to/project   # Run in specific project
#   ./ralph-once.sh -m gpt-5.2-high    # Use specific model
#
# After running:
#   - Review the changes made
#   - Check git log for commits
#   - If satisfied, run ralph-setup.sh or ralph-loop.sh for full loop
#
# Requirements:
#   - ralph/prd.json and jq
#   - Git repository
#   - cursor-agent CLI installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: Single Iteration (Human-in-the-Loop)

Runs exactly ONE iteration, then stops for review.
This is the recommended way to test your task definition.

Usage:
  ./ralph-once.sh [options] [workspace]

Options:
  -m, --model MODEL      Model to use (default: opus-4.5-thinking)
  -h, --help             Show this help

Examples:
  ./ralph-once.sh                        # Run one iteration
  ./ralph-once.sh -m sonnet-4.5-thinking # Use Sonnet model
  
After reviewing the results:
  - If satisfied: run ./ralph-setup.sh for full loop
  - If issues: fix them, update ralph/prd.json or guardrails, run again
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use -h for help."
      exit 1
      ;;
    *)
      # Positional argument = workspace
      WORKSPACE="$1"
      shift
      ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Resolve workspace
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$(pwd)"
  elif [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi
  
  # Show banner
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Single US Run (Human-in-the-Loop)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  This runs ONE agent on the next incomplete User Story, then stops."
  echo "  Use this to test before running the full loop."
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi
  
  # Initialize .ralph directory
  init_ralph_dir "$WORKSPACE"
  
  echo "Workspace: $WORKSPACE"
  echo "Model:     $MODEL"
  echo ""
  
  # Show PRD summary
  show_task_summary "$WORKSPACE"
  
  local progress_line
  progress_line=$(count_criteria "$WORKSPACE")
  local done_criteria="${progress_line%%:*}"
  local total_criteria="${progress_line##*:}"
  local remaining=$((total_criteria - done_criteria))
  
  if [[ "$remaining" -eq 0 ]] && [[ "$total_criteria" -gt 0 ]]; then
    echo "🎉 PRD already complete! All User Stories are done."
    exit 0
  fi
  
  local us
  us=$(prd_get_next_us "$WORKSPACE")
  if [[ -z "$us" ]]; then
    echo "No incomplete User Story."
    exit 0
  fi
  
  # Confirm
  read -p "Run single US ($us)? [Y/n] " -n 1 -r
  echo ""
  
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  
  # Commit any uncommitted work first
  cd "$WORKSPACE"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: checkpoint before single US" || true
  fi
  
  echo ""
  echo "🚀 Running single US: $us"
  echo ""
  
  local signal
  signal=$(run_iteration "$WORKSPACE" "$us" "$SCRIPT_DIR")
  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📋 Single US Run Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  
  case "$signal" in
    US-DONE|COMPLETE)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 PRD completed!"
      else
        echo "✅ $us done. More User Stories remain."
      fi
      ;;
    "GUTTER")
      echo "🚨 Gutter detected - agent got stuck."
      echo "   Review .ralph/errors.log and .ralph/guardrails.md"
      ;;
    "ROTATE")
      echo "🔄 Context rotation was triggered (token limit)."
      echo "   Review progress; next run will retry this US with a new agent."
      ;;
    *)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 PRD completed!"
      else
        local remaining_count=${task_status#INCOMPLETE:}
        echo "Agent finished with $remaining_count User Story(ies) remaining."
      fi
      ;;
  esac
  
  echo ""
  echo "Review: git log --oneline -5; cat progress.txt; cat ralph/prd.json"
  echo "Next: ./ralph-setup.sh for full loop, or ./ralph-once.sh to run another US"
  echo ""
}

main