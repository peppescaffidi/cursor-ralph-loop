#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/ within the project.

# =============================================================================
# SOURCE DEPENDENCIES
# =============================================================================

# Get the directory where this script lives
_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the task parser for YAML backend support
if [[ -f "$_RALPH_SCRIPT_DIR/task-parser.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/task-parser.sh"
  _TASK_PARSER_AVAILABLE=1
else
  _TASK_PARSER_AVAILABLE=0
fi

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Token thresholds FOR EACH USER STORY
WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"

# Iteration limits (when using PRD: max runs per single US, e.g. 3 retries per US)
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"

# PRD and progress paths (relative to workspace root; both live in tasks/)
PRD_FILE="tasks/prd.json"
PROGRESS_TXT="tasks/progress.txt"

# Model selection
DEFAULT_MODEL="auto"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# SOURCE RETRY UTILITIES
# =============================================================================

# Source retry logic utilities
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
if [[ -f "$SCRIPT_DIR/ralph-retry.sh" ]]; then
  source "$SCRIPT_DIR/ralph-retry.sh"
fi

# =============================================================================
# BASIC HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Used so prd.json and progress.txt (both in tasks/)
get_workspace_root() {
  local arg="${1:-.}"
  if [[ -n "$arg" && "$arg" != "." ]]; then
    echo "$(cd "$arg" && pwd)"
    return
  fi
  # Scripts in repo: PROJECT_ROOT/.cursor/ralph-scripts → project root = SCRIPT_DIR/../..
  if [[ "$_RALPH_SCRIPT_DIR" == *"/.cursor/ralph-scripts" ]]; then
    echo "$(cd "$_RALPH_SCRIPT_DIR/../.." && pwd)"
    return
  fi
  echo "$(pwd)"
}

# Get current iteration from .ralph/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
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

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# =============================================================================
# PRD HELPERS (prd.json as source of truth)
# =============================================================================

# Path to prd.json in workspace
_get_prd_path() {
  local workspace="${1:-.}"
  echo "$workspace/$PRD_FILE"
}

# Check if PRD is complete (all userStories have passes == true)
# Returns: COMPLETE or INCOMPLETE:N (N = count of incomplete US)
prd_is_complete() {
  local workspace="$1"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  if [[ ! -f "$prd_path" ]]; then
    echo "NO_PRD_FILE"
    return
  fi
  
  local total incomplete
  total=$(jq -r '.userStories | length' "$prd_path" 2>/dev/null) || total=0
  incomplete=$(jq -r '[.userStories[] | select(.passes != true)] | length' "$prd_path" 2>/dev/null) || incomplete="$total"
  
  if [[ "$incomplete" -eq 0 ]] && [[ "$total" -gt 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$incomplete"
  fi
}

# Get the next incomplete User Story id (first by array order with passes != true)
# Returns: US-XXX or empty if all complete
prd_get_next_us() {
  local workspace="$1"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  if [[ ! -f "$prd_path" ]]; then
    echo ""
    return
  fi
  
  jq -r '.userStories[] | select(.passes != true) | .id' "$prd_path" 2>/dev/null | head -1
}

# Mark a User Story as passed in prd.json (set .passes = true for that US)
prd_mark_us_passes() {
  local workspace="$1"
  local us_id="$2"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  if [[ ! -f "$prd_path" ]]; then
    echo "ERROR: No prd.json at $prd_path" >&2
    return 1
  fi
  
  local tmp_file
  tmp_file=$(mktemp)
  jq --arg id "$us_id" '.userStories |= map(if .id == $id then .passes = true else . end)' "$prd_path" > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
  mv "$tmp_file" "$prd_path"
}

# Show PRD summary (project, description, US list with pass/fail)
prd_show_summary() {
  local workspace="$1"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  if [[ ! -f "$prd_path" ]]; then
    echo "❌ No $PRD_FILE found"
    return 1
  fi
  
  local project description total done_us
  project=$(jq -r '.project // "—"' "$prd_path" 2>/dev/null)
  description=$(jq -r '.description // ""' "$prd_path" 2>/dev/null)
  total=$(jq -r '.userStories | length' "$prd_path" 2>/dev/null) || total=0
  done_us=$(jq -r '[.userStories[] | select(.passes == true)] | length' "$prd_path" 2>/dev/null) || done_us=0
  
  echo "📋 PRD Summary: $project"
  echo "─────────────────────────────────────────────────────────────────"
  [[ -n "$description" ]] && echo "$description"
  echo "─────────────────────────────────────────────────────────────────"
  echo "User Stories: $done_us / $total complete"
  jq -r '.userStories[] | "  \(if .passes == true then "✅" else "⬜" end) \(.id): \(.title)"' "$prd_path" 2>/dev/null || true
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  echo "Model:    $MODEL"
  echo ""
}

# =============================================================================
# TASK MANAGEMENT (PRD-based: check_task_complete uses prd_is_complete)
# =============================================================================

# Check if task is complete (PRD: all userStories have passes == true)
check_task_complete() {
  prd_is_complete "$1"
}

# Count criteria from PRD (returns done:total)
count_criteria() {
  local workspace="${1:-.}"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  if [[ ! -f "$prd_path" ]]; then
    echo "0:0"
    return
  fi
  
  local total done_count
  total=$(jq -r '.userStories | length' "$prd_path" 2>/dev/null) || total=0
  done_count=$(jq -r '[.userStories[] | select(.passes == true)] | length' "$prd_path" 2>/dev/null) || done_count=0
  echo "$done_count:$total"
}

# =============================================================================
# TASK PARSER CONVENIENCE WRAPPERS (legacy, for task-parser.sh if used elsewhere)
# =============================================================================

# Get the next task to work on (wrapper for task-parser.sh)
# Returns: task_id|status|description or empty
get_next_task_info() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_next_task "$workspace"
  else
    echo ""
  fi
}

# Mark a specific task complete by line-based ID
# Usage: complete_task "$workspace" "line_15"
complete_task() {
  local workspace="${1:-.}"
  local task_id="$2"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    mark_task_complete "$workspace" "$task_id"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# List all tasks with their status
# Usage: list_all_tasks "$workspace"
list_all_tasks() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_all_tasks "$workspace"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# Refresh task cache (useful after external edits)
refresh_task_cache() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    # Invalidate and re-parse
    rm -f "$workspace/.ralph/$TASK_MTIME_FILE" 2>/dev/null
    parse_tasks "$workspace"
  fi
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for a single User Story
# Args: workspace, us_id (e.g. US-001)
build_prompt() {
  local workspace="$1"
  local us_id="$2"
  local prd_path
  prd_path=$(_get_prd_path "$workspace")
  
  local us_json
  us_json=$(jq -r --arg id "$us_id" '.userStories[] | select(.id == $id) | @json' "$prd_path" 2>/dev/null) || us_json=""
  
  cat << EOF
# Ralph: Work on a single User Story

You are an autonomous development agent. Work ONLY on the User Story below.

## FIRST: Read State Files

Before doing anything:
1. Read \`tasks/prd.json\` - full PRD (project, all user stories)
2. Read \`tasks/progress.txt\` - what previous agents did (append your own entry when done)
3. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
4. Read \`.ralph/errors.log\` - recent failures to avoid

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`, \`pnpm init\`, etc.)
- If you need to scaffold, use flags like \`--no-git\` or scaffold into the current directory (\`.\`)
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Commit early and often. After completing the User Story (or significant step):
\`git add -A && git commit -m 'ralph: <describe what you did>'\`
Push after every 2-3 commits: \`git push\`

## YOUR TASK: This User Story Only

Work ONLY on this User Story. Do not start other user stories.

\`\`\`json
$us_json
\`\`\`

1. Implement or complete the acceptance criteria for this User Story.
2. Run typecheck and tests (e.g. \`npm run typecheck\`, \`npm run test\`) and fix any failures.
3. **When this User Story is fully done**: append one line to \`tasks/progress.txt\` with date, US id, and short summary (e.g. \`[YYYY-MM-DD] $us_id: summary of what was done\`).
4. **Then** output exactly: \`<ralph>US-DONE $us_id</ralph>\`
   - The script will update \`tasks/prd.json\` (set \`passes: true\` for this US). Do NOT edit prd.json yourself.
5. If stuck 3+ times on the same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails: check \`.ralph/errors.log\`, figure out root cause, add a Sign to \`.ralph/guardrails.md\`.

## Context Rotation

If you see a warning that context is running low: finish your current edit, commit, append to \`tasks/progress.txt\`, then output \`<ralph>US-DONE $us_id</ralph>\` if done or you will be rotated and the next agent will retry this same US.

Begin by reading the state files, then work on this User Story only.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent run for one User Story (always new agent, no resume)
# Args: workspace, us_id (e.g. US-001), script_dir
# Returns: signal (ROTATE, GUTTER, COMPLETE, US-DONE, DEFER, or empty)
run_iteration() {
  local workspace="$1"
  local us_id="$2"
  local script_dir="${3:-$(dirname "${BASH_SOURCE[0]}")}"
  
  local prompt
  prompt=$(build_prompt "$workspace" "$us_id")
  local fifo="$workspace/.ralph/.parser_fifo"
  local prompt_file="$workspace/.ralph/.current_prompt"
  
  rm -f "$fifo"
  mkfifo "$fifo"
  
  # Write prompt to file so we avoid shell quoting/truncation when passing to cursor-agent
  # (prompt can contain ", $, newlines; passing as arg with eval "$cmd \"$prompt\"" breaks)
  printf '%s' "$prompt" > "$prompt_file"
  
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph: $us_id" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2
  
  log_progress "$workspace" "**Session $us_id started** (model: $MODEL)"
  
  # Always new agent (no --resume).
  # -p --force: non-interactive, allow commands (no grant prompts).
  # --workspace: explicit workspace; prompt from file to avoid quoting/size issues.
  # For headless: set CURSOR_API_KEY so the agent doesn't need interactive login.
  cd "$workspace"
  
  # Raw agent output for debugging (overwritten each run)
  local raw_log="$workspace/.ralph/agent_raw.log"
  
  spinner "$workspace" &
  local spinner_pid=$!
  
  (
    # Ensure API key is visible to cursor-agent (inherit from parent or .env)
    [[ -n "${CURSOR_API_KEY:-}" ]] && export CURSOR_API_KEY
    # Use last line of MODEL and trim (avoid "Select model:" etc. if capture ever included menu text)
    local effective_model
    effective_model="$(echo "$MODEL" | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # In headless/API mode cursor-agent does not accept model "auto"; omit --model to use CLI default
    local model_arg=""
    [[ -n "$effective_model" && "$effective_model" != "auto" ]] && model_arg="--model $effective_model"
    cursor-agent -p --force --output-format stream-json $model_arg --workspace "$workspace" "$(cat "$prompt_file")" 2>&1 \
      | tee "$raw_log" \
      | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
  ) &
  local agent_pid=$!
  
  local signal=""
  local us_done_id=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2
        echo "🔄 Context rotation (token limit) - stopping agent; next agent will retry this US..." >&2
        kill $agent_pid 2>/dev/null || true
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        ;;
      "GUTTER")
        printf "\r\033[K" >&2
        echo "🚨 Gutter detected - agent may be stuck..." >&2
        signal="GUTTER"
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2
        echo "✅ Agent signaled COMPLETE!" >&2
        signal="COMPLETE"
        ;;
      "DEFER")
        printf "\r\033[K" >&2
        echo "⏸️  Rate limit or transient error - deferring for retry..." >&2
        signal="DEFER"
        kill $agent_pid 2>/dev/null || true
        break
        ;;
      US-DONE\ *)
        us_done_id="${line#US-DONE }"
        printf "\r\033[K" >&2
        echo "✅ Agent signaled US-DONE $us_done_id" >&2
        prd_mark_us_passes "$workspace" "$us_done_id" && echo "   Updated $PRD_FILE" >&2
        signal="US-DONE"
        us_done_id="$us_done_id"
        break
        ;;
    esac
  done < "$fifo"
  
  wait $agent_pid 2>/dev/null || true
  kill $spinner_pid 2>/dev/null || true
  wait $spinner_pid 2>/dev/null || true
  printf "\r\033[K" >&2
  
  rm -f "$fifo"
  
  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop (one agent per User Story, max MAX_ITERATIONS runs per US)
# Args: workspace, script_dir
# Uses global: MAX_ITERATIONS (max retries per US), MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  
  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi
  
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi
  
  echo ""
  echo "🚀 Starting Ralph loop (one agent per US, max $MAX_ITERATIONS runs per US)..."
  echo ""
  
  # Ensure tasks/progress.txt exists
  if [[ ! -f "$workspace/$PROGRESS_TXT" ]]; then
    mkdir -p "$(dirname "$workspace/$PROGRESS_TXT")"
    echo "=== Ralph progress log ===" > "$workspace/$PROGRESS_TXT"
  fi
  
  while true; do
    local task_status
    task_status=$(check_task_complete "$workspace")
    [[ "$task_status" == "COMPLETE" ]] && break
    
    local us
    us=$(prd_get_next_us "$workspace")
    [[ -z "$us" ]] && break
    
    local retry=1
    local us_done=false
    while [[ $retry -le $MAX_ITERATIONS ]]; do
      echo ""
      echo "📌 $us (attempt $retry / $MAX_ITERATIONS)"
      local signal
      signal=$(run_iteration "$workspace" "$us" "$script_dir")
      task_status=$(check_task_complete "$workspace")
      
      if [[ "$task_status" == "COMPLETE" ]]; then
        log_progress "$workspace" "**$us ended** - ✅ PRD COMPLETE"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "🎉 RALPH COMPLETE! All User Stories satisfied."
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
          echo "📝 Opening pull request..."
          git push -u origin "$USE_BRANCH" 2>/dev/null || git push
          command -v gh &> /dev/null && gh pr create --fill || echo "⚠️  Create PR manually."
        fi
        return 0
      fi
      
      case "$signal" in
        US-DONE|COMPLETE)
          log_progress "$workspace" "**$us ended** - ✅ $signal"
          us_done=true
          break
          ;;
        ROTATE)
          log_progress "$workspace" "**$us ended** - 🔄 Context rotation; retrying same US with new agent"
          echo "🔄 Retrying $us with fresh agent..."
          retry=$((retry + 1))
          ;;
        GUTTER)
          log_progress "$workspace" "**$us ended** - 🚨 GUTTER"
          echo "🚨 Gutter detected. Check .ralph/errors.log"
          return 1
          ;;
        DEFER)
          log_progress "$workspace" "**$us ended** - ⏸️ DEFER (rate limit)"
          local defer_delay=30
          if type calculate_backoff_delay &>/dev/null; then
            local defer_attempt=${DEFER_COUNT:-1}
            DEFER_COUNT=$((defer_attempt + 1))
            defer_delay=$(($(calculate_backoff_delay "$defer_attempt" 15 120 true) / 1000))
          fi
          echo "⏸️  Waiting ${defer_delay}s before retry..."
          sleep "$defer_delay"
          ;;
        *)
          log_progress "$workspace" "**$us ended** - Agent finished without US-DONE (attempt $retry)"
          echo "💡 Check $workspace/.ralph/agent_raw.log to see what cursor-agent output (or if it exited with no output)."
          retry=$((retry + 1))
          ;;
      esac
      sleep 2
    done
    
    if [[ "$us_done" != "true" ]]; then
      log_progress "$workspace" "**$us skipped** - Max runs ($MAX_ITERATIONS) reached without US-DONE"
      echo "⚠️  Max runs for $us reached; moving to next US."
    fi
    sleep 2
  done
  
  task_status=$(check_task_complete "$workspace")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 RALPH COMPLETE!"
    [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]] && git push -u origin "$USE_BRANCH" 2>/dev/null && command -v gh &> /dev/null && gh pr create --fill
    return 0
  fi
  
  echo "⚠️  Loop ended. Some User Stories may be incomplete. Check $PRD_FILE and $PROGRESS_TXT"
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local prd_path="$workspace/$PRD_FILE"
  
  # Check for jq
  if ! command -v jq &> /dev/null; then
    echo "❌ jq not found (required to read prd.json)"
    echo ""
    echo "Install via: brew install jq  (macOS) or your package manager"
    return 1
  fi
  
  # Check for PRD file
  if [[ ! -f "$prd_path" ]]; then
    echo "❌ No $PRD_FILE found in $workspace"
    echo ""
    echo "Create tasks/prd.json with project, userStories (id, title, description, acceptanceCriteria, priority, passes)."
    return 1
  fi
  
  # Check for cursor-agent CLI
  if ! command -v cursor-agent &> /dev/null; then
    echo "❌ cursor-agent CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://cursor.com/install -fsS | bash"
    return 1
  fi
  
  # Check for stream-parser (required for run_iteration)
  local script_dir="${SCRIPT_DIR:-$_RALPH_SCRIPT_DIR}"
  if [[ -z "$script_dir" ]]; then
    script_dir="$(dirname "${BASH_SOURCE[0]}")"
  fi
  local stream_parser="$script_dir/stream-parser.sh"
  if [[ ! -x "$stream_parser" ]]; then
    echo "❌ stream-parser.sh not found or not executable: $stream_parser"
    echo ""
    echo "Ralph requires stream-parser.sh for token tracking and gutter detection."
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi
  
  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary (PRD-based)
show_task_summary() {
  prd_show_summary "$1"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}