# ============================================
# AI ENGINE ABSTRACTION
# ============================================

run_ai_command() {
  local prompt=$1
  local output_file=$2

  case "$AI_ENGINE" in
    opencode)
      # OpenCode: use 'run' command with JSON format and permissive settings
      OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
        --format json \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    cursor)
      # Cursor agent: use --print for non-interactive, --force to allow all commands
      agent --print --force \
        --output-format stream-json \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    qwen)
      # Qwen-Code: use CLI with JSON format and auto-approve tools
      qwen --output-format stream-json \
        --approval-mode yolo \
        -p "$prompt" > "$output_file" 2>&1 &
      ;;
    codex)
      CODEX_LAST_MESSAGE_FILE="${output_file}.last"
      rm -f "$CODEX_LAST_MESSAGE_FILE"
      codex exec --full-auto \
        --json \
        --output-last-message "$CODEX_LAST_MESSAGE_FILE" \
        "$prompt" > "$output_file" 2>&1 &
      ;;
    *)
      # Claude Code: use existing approach
      claude --dangerously-skip-permissions \
        --verbose \
        --output-format stream-json \
        -p "$prompt" > "$output_file" 2>&1 &
      ;;
  esac

  ai_pid=$!
}

parse_ai_result() {
  local result=$1
  local response=""
  local input_tokens=0
  local output_tokens=0
  local actual_cost="0"

  case "$AI_ENGINE" in
    opencode)
      # OpenCode JSON format: uses step_finish for tokens and text events for response
      local step_finish
      step_finish=$(echo "$result" | grep '"type":"step_finish"' | tail -1 || echo "")

      if [[ -n "$step_finish" ]]; then
        input_tokens=$(echo "$step_finish" | jq -r '.part.tokens.input // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$step_finish" | jq -r '.part.tokens.output // 0' 2>/dev/null || echo "0")
        # OpenCode provides actual cost directly
        actual_cost=$(echo "$step_finish" | jq -r '.part.cost // 0' 2>/dev/null || echo "0")
      fi

      # Get text response from text events
      response=$(echo "$result" | grep '"type":"text"' | jq -rs 'map(.part.text // "") | join("")' 2>/dev/null || echo "")

      # If no text found, indicate task completed
      if [[ -z "$response" ]]; then
        response="Task completed"
      fi
      ;;
    cursor)
      # Cursor agent: parse stream-json output
      # Cursor doesn't provide token counts, but does provide duration_ms

      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)

      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "Task completed"' 2>/dev/null || echo "Task completed")
        # Cursor provides duration instead of tokens
        local duration_ms
        duration_ms=$(echo "$result_line" | jq -r '.duration_ms // 0' 2>/dev/null || echo "0")
        # Store duration in output_tokens field for now (we'll handle it specially)
        # Use negative value as marker that this is duration, not tokens
        if [[ "$duration_ms" =~ ^[0-9]+$ ]] && [[ "$duration_ms" -gt 0 ]]; then
          # Encode duration: store as-is, we track separately
          actual_cost="duration:$duration_ms"
        fi
      fi

      # Get response from assistant message if result is empty
      if [[ -z "$response" ]] || [[ "$response" == "Task completed" ]]; then
        local assistant_msg
        assistant_msg=$(echo "$result" | grep '"type":"assistant"' | tail -1)
        if [[ -n "$assistant_msg" ]]; then
          response=$(echo "$assistant_msg" | jq -r '.message.content[0].text // .message.content // "Task completed"' 2>/dev/null || echo "Task completed")
        fi
      fi

      # Tokens remain 0 for Cursor (not available)
      input_tokens=0
      output_tokens=0
      ;;
    qwen)
      # Qwen-Code stream-json parsing (similar to Claude Code)
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)

      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
        input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
      fi

      # Fallback when no response text was parsed, similar to OpenCode behavior
      if [[ -z "$response" ]]; then
        response="Task completed"
      fi
      ;;
    codex)
      if [[ -n "$CODEX_LAST_MESSAGE_FILE" ]] && [[ -f "$CODEX_LAST_MESSAGE_FILE" ]]; then
        response=$(cat "$CODEX_LAST_MESSAGE_FILE" 2>/dev/null || echo "")
        # Codex sometimes prefixes a generic completion line; drop it for readability.
        response=$(printf '%s' "$response" | sed '1{/^Task completed successfully\.[[:space:]]*$/d;}')
      fi
      input_tokens=0
      output_tokens=0
      ;;
    *)
      # Claude Code stream-json parsing
      local result_line
      result_line=$(echo "$result" | grep '"type":"result"' | tail -1)

      if [[ -n "$result_line" ]]; then
        response=$(echo "$result_line" | jq -r '.result // "No result text"' 2>/dev/null || echo "Could not parse result")
        input_tokens=$(echo "$result_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$result_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo "0")
      fi
      ;;
  esac

  # Sanitize token counts
  [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
  [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0

  echo "$response"
  echo "---TOKENS---"
  echo "$input_tokens"
  echo "$output_tokens"
  echo "$actual_cost"
}

check_for_errors() {
  local result=$1

  if echo "$result" | grep -q '"type":"error"'; then
    local error_msg
    error_msg=$(echo "$result" | grep '"type":"error"' | head -1 | jq -r '.error.message // .message // .' 2>/dev/null || echo "Unknown error")
    echo "$error_msg"
    return 1
  fi

  return 0
}

has_tool_usage() {
  local result=$1

  if echo "$result" | grep -qE '"type":"tool_use"'; then
    return 0
  fi
  if echo "$result" | grep -qE '"tool":"[A-Za-z_]+"' ; then
    return 0
  fi
  if echo "$result" | grep -qE '"tool_name":"[A-Za-z_]+"' ; then
    return 0
  fi
  if echo "$result" | grep -qE '"name":"(read|glob|grep|write|edit|patch|apply_patch|run_shell_command|shell|exec|bash|cmd)"'; then
    return 0
  fi
  # Codex patterns
  if echo "$result" | grep -qE '"type":"tool_call"'; then
    return 0
  fi
  if echo "$result" | grep -qE '"function":\{[^}]*"name":"'; then
    return 0
  fi

  return 1
}

has_repo_changes_since() {
  local start_head="$1"
  local start_status="$2"
  local repo_dir="${3:-}"
  local head_now=""
  local status_now=""

  if [[ -n "$repo_dir" ]]; then
    head_now=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    status_now=$(git -C "$repo_dir" status --porcelain 2>/dev/null || echo "")
  else
    head_now=$(git rev-parse HEAD 2>/dev/null || echo "")
    status_now=$(git status --porcelain 2>/dev/null || echo "")
  fi

  if [[ -n "$start_head" && -n "$head_now" && "$head_now" != "$start_head" ]]; then
    return 0
  fi
  if [[ "$status_now" != "$start_status" ]]; then
    return 0
  fi

  return 1
}

# Check if error is a rate limit / quota exceeded error
is_rate_limit_error() {
  local error_msg=$1

  # Common rate limit / quota error patterns across providers
  local patterns=(
    "rate.?limit"
    "quota.?exceeded"
    "too.?many.?requests"
    "429"
    "resource.?exhausted"
    "capacity"
    "overloaded"
    "usage.?limit"
    "billing"
    "insufficient.?quota"
    "free.?tier"
    "RPM"
    "TPM"
    "tokens?.?per.?minute"
    "requests?.?per.?minute"
  )

  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  for pattern in "${patterns[@]}"; do
    if echo "$lower_msg" | grep -qiE "$pattern"; then
      return 0  # Is a rate limit error
    fi
  done

  return 1  # Not a rate limit error
}

# Switch to fallback engine
switch_to_fallback() {
  if [[ ${#FALLBACK_ENGINES[@]} -eq 0 ]]; then
    return 1  # No fallback configured
  fi

  local next_engine=""

  while [[ $FALLBACK_INDEX -lt ${#FALLBACK_ENGINES[@]} ]]; do
    next_engine="${FALLBACK_ENGINES[$FALLBACK_INDEX]}"
    FALLBACK_INDEX=$((FALLBACK_INDEX + 1))

    if [[ -z "$next_engine" ]] || [[ "$next_engine" == "$AI_ENGINE" ]]; then
      continue
    fi

    ORIGINAL_ENGINE="$AI_ENGINE"
    AI_ENGINE="$next_engine"
    FALLBACK_USED=true

    log_warn "Switching from $ORIGINAL_ENGINE to $AI_ENGINE due to rate limit"
    return 0
  done

  return 1
}
