# ============================================
# SINGLE TASK EXECUTION
# ============================================

run_single_task() {
  local task_name="${1:-}"
  local task_num="${2:-$iteration}"

  retry_count=0

  echo ""
  echo "${BOLD}>>> Task $task_num${RESET}"

  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  local blocked_count=${#blocked_issues[@]}
  echo "${DIM}    Processed: $session_processed | Blocked: $blocked_count | Remaining: $remaining${RESET}"
  echo "--------------------------------------------"

  # Get current task for display
  local current_task
  if [[ -n "$task_name" ]]; then
    current_task="$task_name"
  else
    # Use unclaimed task finder to coordinate with other instances
    current_task=$(get_next_unclaimed_task)
  fi

  if [[ -z "$current_task" ]]; then
    log_info "No more tasks found"
    return 2
  fi

  # Track for blocked issue handling in main loop
  LAST_ATTEMPTED_TASK="$current_task"

  current_step="Thinking"

  # Update project board: task starting
  if [[ "$PRD_SOURCE" == "github" ]]; then
    project_board_task_started "$current_task"
  fi

  # Create branch if needed
  local branch_name=""
  if [[ "$BRANCH_PER_TASK" == true ]]; then
    branch_name=$(create_task_branch "$current_task")
    log_info "Working on branch: $branch_name"
  fi

  local task_start_head=""
  task_start_head=$(git rev-parse HEAD 2>/dev/null || echo "")
  local task_start_status=""
  task_start_status=$(git status --porcelain 2>/dev/null || echo "")

  # Temp file for AI output
  tmpfile=$(mktemp)

  # Build the prompt
  local prompt
  prompt=$(build_prompt "$current_task")

  if [[ "$DRY_RUN" == true ]]; then
    log_info "DRY RUN - Would execute:"
    echo "${DIM}$prompt${RESET}"
    rm -f "$tmpfile"
    tmpfile=""
    return_to_base_branch
    cleanup_failed_branch "$branch_name"
    return 0
  fi

  # Run with retry logic
  while [[ $retry_count -lt $MAX_RETRIES ]]; do
    # TEST MODE: Skip AI call and inject fake error immediately
    if [[ "$TEST_FALLBACK" == true ]] && [[ "$FALLBACK_USED" == false ]]; then
      log_warn "TEST MODE: Skipping $AI_ENGINE, simulating rate limit"
      echo '{"type":"error","error":{"message":"Resource exhausted: quota exceeded"}}' > "$tmpfile"
      sleep 1  # Brief pause for realism
    else
      # Start AI command
      run_ai_command "$prompt" "$tmpfile"

      # Start progress monitor in background
      monitor_progress "$tmpfile" "${current_task:0:40}" &
      monitor_pid=$!

      # Wait for AI to finish with timeout and stuck detection
      local ai_start=$SECONDS
      local AI_TIMEOUT_SECS=1800    # 30 min hard timeout
      local AI_STUCK_WARN_SECS=900  # 15 min stuck warning
      local ai_stuck_warned=false

      while kill -0 "$ai_pid" 2>/dev/null; do
        local ai_elapsed=$((SECONDS - ai_start))

        if [[ $ai_elapsed -ge $AI_STUCK_WARN_SECS ]] && [[ "$ai_stuck_warned" == false ]]; then
          ai_stuck_warned=true
          notify_task_stuck "${current_task:0:50}" "$((ai_elapsed / 60))"
          log_warn "AI agent running for ${ai_elapsed}s on: ${current_task:0:50}"
        fi

        if [[ $ai_elapsed -ge $AI_TIMEOUT_SECS ]]; then
          log_error "AI agent timed out after $((ai_elapsed / 60))m — killing"
          notify_error "Agent timed out on: ${current_task:0:50}"
          kill "$ai_pid" 2>/dev/null || true
          sleep 1
          kill -9 "$ai_pid" 2>/dev/null || true
          break
        fi

        sleep 2
      done
      wait "$ai_pid" 2>/dev/null || true

      # Stop the monitor
      kill "$monitor_pid" 2>/dev/null || true
      wait "$monitor_pid" 2>/dev/null || true
      monitor_pid=""

      # Show completion
      tput cr 2>/dev/null || printf "\r"
      tput el 2>/dev/null || true
    fi

    # Read result
    local result
    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    # Check for empty response
    if [[ -z "$result" ]]; then
      ((retry_count++)) || true
      log_error "Empty response (attempt $retry_count/$MAX_RETRIES)"

      # Empty responses after multiple retries may indicate rate limiting
      if [[ $retry_count -ge $MAX_RETRIES ]]; then
        if switch_to_fallback; then
          retry_count=0
          log_info "Continuing with ${AI_ENGINE}..."
          sleep 2
          continue
        fi
      fi

      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      cleanup_failed_branch "$branch_name"
      return 1
    fi

    # Check for API errors
    local error_msg
    if ! error_msg=$(check_for_errors "$result"); then
      ((retry_count++)) || true
      log_error "API error: $error_msg (attempt $retry_count/$MAX_RETRIES)"

      # Check if this is a rate limit error and we have a fallback
      if is_rate_limit_error "$error_msg"; then
        if switch_to_fallback; then
          # Successfully switched to fallback - reset retry count and continue
          retry_count=0
          log_info "Continuing with ${AI_ENGINE}..."
          sleep 2  # Brief pause before trying new engine
          continue
        fi
      fi

      if [[ $retry_count -lt $MAX_RETRIES ]]; then
        log_info "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
        continue
      fi
      rm -f "$tmpfile"
      tmpfile=""
      return_to_base_branch
      cleanup_failed_branch "$branch_name"
      return 1
    fi

    local repo_changed=false
    if has_repo_changes_since "$task_start_head" "$task_start_status"; then
      repo_changed=true
    fi

    if [[ "$result" == *"TOOL_ACCESS_FAILED"* ]]; then
      log_error "Tool access failed; stopping."
      rm -f "$tmpfile"
      tmpfile=""
      if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
        rm -f "$CODEX_LAST_MESSAGE_FILE"
        CODEX_LAST_MESSAGE_FILE=""
      fi
      return_to_base_branch
      cleanup_failed_branch "$branch_name"
      return 4
    fi

    if ! has_tool_usage "$result" && [[ "$repo_changed" != true ]]; then
      log_error "No tool usage detected; failing task."
      rm -f "$tmpfile"
      tmpfile=""
      if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
        rm -f "$CODEX_LAST_MESSAGE_FILE"
        CODEX_LAST_MESSAGE_FILE=""
      fi
      return_to_base_branch
      cleanup_failed_branch "$branch_name"
      return 4
    fi

    # Parse the result
    local parsed
    parsed=$(parse_ai_result "$result")
    local response
    response=$(echo "$parsed" | sed '/^---TOKENS---$/,$d')
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    local input_tokens
    input_tokens=$(echo "$token_data" | sed -n '1p')
    local output_tokens
    output_tokens=$(echo "$token_data" | sed -n '2p')
    local actual_cost
    actual_cost=$(echo "$token_data" | sed -n '3p')

    printf "  ${GREEN}✓${RESET} %-16s │ %s\n" "Done" "${current_task:0:40}"

    if [[ -n "$response" ]]; then
      echo ""
      echo "$response"
    fi

    # Sanitize values
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0

    # Update totals
    total_input_tokens=$((total_input_tokens + input_tokens))
    total_output_tokens=$((total_output_tokens + output_tokens))

    # Track actual cost for OpenCode, or duration for Cursor
    if [[ -n "$actual_cost" ]]; then
      if [[ "$actual_cost" == duration:* ]]; then
        # Cursor duration tracking
        local dur_ms="${actual_cost#duration:}"
        [[ "$dur_ms" =~ ^[0-9]+$ ]] && total_duration_ms=$((total_duration_ms + dur_ms))
      elif [[ "$actual_cost" != "0" ]] && command -v bc &>/dev/null; then
        # OpenCode cost tracking
        total_actual_cost=$(echo "scale=6; $total_actual_cost + $actual_cost" | bc 2>/dev/null || echo "$total_actual_cost")
      fi
    fi

    rm -f "$tmpfile"
    tmpfile=""
    if [[ "$AI_ENGINE" == "codex" ]] && [[ -n "$CODEX_LAST_MESSAGE_FILE" ]]; then
      rm -f "$CODEX_LAST_MESSAGE_FILE"
      CODEX_LAST_MESSAGE_FILE=""
    fi

    # Mark task complete for GitHub issues (since AI can't do it)
    if [[ "$PRD_SOURCE" == "github" ]]; then
      local head_after
      head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
      local has_commits=false
      local has_code=false

      if [[ -n "$task_start_head" && -n "$head_after" && "$task_start_head" != "$head_after" ]]; then
        has_commits=true
        if has_code_changes_between "$task_start_head" "$head_after"; then
          has_code=true
        fi
      fi

      # Check if this issue type allows closing without code changes
      local no_code_ok=false
      if issue_allows_no_code "$current_task"; then
        no_code_ok=true
        log_info "Issue has no-code-required label; documentation/decision changes are acceptable"
      fi

      if [[ "$has_code" == true ]]; then
        # Normal case: code changes detected
        local completion_comment="## Task Completed by Ralphy

**Summary:**
${response:-Task implementation completed successfully.}

**Commits:** \`${task_start_head:0:7}\`..\`${head_after:0:7}\`
**Engine:** ${AI_ENGINE}"
        mark_task_complete "$current_task" "$completion_comment"
        project_board_task_completed "$current_task" "${branch_name:-}"
        ((session_processed++)) || true
      elif [[ "$no_code_ok" == true ]]; then
        # No code changes but issue allows it (decision/docs/chore)
        local completion_comment="## Task Completed by Ralphy

**Summary:**
${response:-Task completed (no code changes required).}

**Type:** Documentation/Decision/Chore
**Engine:** ${AI_ENGINE}"
        mark_task_complete "$current_task" "$completion_comment"
        project_board_task_completed "$current_task" "${branch_name:-}"
        ((session_processed++)) || true
      elif [[ "$has_commits" == false ]]; then
        log_error "No new commit created; failing task and leaving issue open: $current_task"
        return_to_base_branch
        cleanup_failed_branch "$branch_name"
        return 3
      else
        log_error "No code changes detected (docs/progress only); failing task and leaving issue open: $current_task"
        log_info "Tip: Add 'no-code-required', 'chore', 'documentation', or 'decision' label to allow closing without code"
        return_to_base_branch
        cleanup_failed_branch "$branch_name"
        return 3
      fi
    else
      # For markdown/yaml, the AI marks the task complete directly
      # We just need to track the session counter
      ((session_processed++)) || true
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]] && [[ -n "$branch_name" ]]; then
      create_pull_request "$branch_name" "$current_task" "Automated implementation by Ralphy"
      # Update project board to "In Review" (overrides "Done" since PR needs review)
      if [[ "$PRD_SOURCE" == "github" ]]; then
        project_board_task_in_review "$current_task" "$branch_name"
      fi
    fi

    # Return to base branch
    return_to_base_branch

    # Merge task branch into base and delete it (skipped if CREATE_PR=true)
    if [[ "$BRANCH_PER_TASK" == true ]] && [[ -n "$branch_name" ]]; then
      merge_and_cleanup_branch "$branch_name"
    fi

    # Check for completion - verify by actually counting remaining tasks
    local remaining_count
    remaining_count=$(count_remaining_tasks | tr -d '[:space:]')
    remaining_count=${remaining_count:-0}
    [[ "$remaining_count" =~ ^[0-9]+$ ]] || remaining_count=0

    if [[ "$remaining_count" -eq 0 ]]; then
      return 2  # All tasks actually complete
    fi

    # AI might claim completion but tasks remain - continue anyway
    if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
      log_debug "AI claimed completion but $remaining_count tasks remain, continuing..."
    fi

    return 0
  done

  return_to_base_branch
  cleanup_failed_branch "$branch_name"
  return 1
}
