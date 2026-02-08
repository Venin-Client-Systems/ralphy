# ============================================
# PROGRESS MONITOR
# ============================================

monitor_progress() {
  local file=$1
  local task=$2
  local start_time
  start_time=$(date +%s)
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0

  task="${task:0:40}"

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    # Check latest output for step indicators
    if [[ -f "$file" ]] && [[ -s "$file" ]]; then
      local content
      content=$(tail -c 5000 "$file" 2>/dev/null || true)

      if echo "$content" | grep -qE 'git commit|"command":"git commit'; then
        current_step="Committing"
      elif echo "$content" | grep -qE 'git add|"command":"git add'; then
        current_step="Staging"
      elif echo "$content" | grep -qE 'progress\.txt'; then
        current_step="Logging"
      elif echo "$content" | grep -qE 'PRD\.md|tasks\.yaml'; then
        current_step="Updating PRD"
      elif echo "$content" | grep -qE 'lint|eslint|biome|prettier'; then
        current_step="Linting"
      elif echo "$content" | grep -qE 'vitest|jest|bun test|npm test|pytest|go test'; then
        current_step="Testing"
      elif echo "$content" | grep -qE '\.test\.|\.spec\.|__tests__|_test\.go'; then
        current_step="Writing tests"
      elif echo "$content" | grep -qE '"tool":"[Ww]rite"|"tool":"[Ee]dit"|"name":"write"|"name":"edit"'; then
        current_step="Implementing"
      elif echo "$content" | grep -qE '"tool":"[Rr]ead"|"tool":"[Gg]lob"|"tool":"[Gg]rep"|"name":"read"|"name":"glob"|"name":"grep"'; then
        current_step="Reading code"
      fi
    fi

    local spinner_char="${spinstr:$spin_idx:1}"
    local step_color=""

    # Color-code steps
    case "$current_step" in
      "Thinking"|"Reading code") step_color="$CYAN" ;;
      "Implementing"|"Writing tests") step_color="$MAGENTA" ;;
      "Testing"|"Linting") step_color="$YELLOW" ;;
      "Staging"|"Committing") step_color="$GREEN" ;;
      *) step_color="$BLUE" ;;
    esac

    # Use tput for cleaner line clearing
    tput cr 2>/dev/null || printf "\r"
    tput el 2>/dev/null || true
    printf "  %s ${step_color}%-16s${RESET} │ %s ${DIM}[%02d:%02d]${RESET}" "$spinner_char" "$current_step" "$task" "$mins" "$secs"

    spin_idx=$(( (spin_idx + 1) % ${#spinstr} ))
    sleep 0.12
  done
}
