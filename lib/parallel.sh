# ============================================
# PARALLEL TASK EXECUTION
# ============================================

# Create an isolated worktree for a parallel agent
# Delegates to guardrail_atomic_worktree for rollback-safe creation + ledger tracking
create_agent_worktree() {
  local task_name="$1"
  local agent_num="$2"
  local issue="${3:-unknown}"

  guardrail_atomic_worktree "$task_name" "$agent_num" "$issue"
}

# Cleanup worktree after agent completes
cleanup_agent_worktree() {
  local worktree_dir="$1"
  local branch_name="$2"
  local log_file="${3:-}"
  local dirty=false

  if [[ -d "$worktree_dir" ]]; then
    if git -C "$worktree_dir" status --porcelain 2>/dev/null | grep -q .; then
      dirty=true
    fi
  fi

  if [[ "$dirty" == true ]]; then
    if [[ -n "$log_file" ]]; then
      echo "Worktree left in place due to uncommitted changes: $worktree_dir" >> "$log_file"
    fi
    return 0
  fi

  # Run from original directory
  (
    cd "$ORIGINAL_DIR" || exit 1
    git worktree remove -f "$worktree_dir" 2>/dev/null || true
  )

  # Kill orphaned tsc/eslint processes from this agent's worktree
  # Only kill those that are descendants of this ralphy instance
  if [[ -n "$worktree_dir" ]] && [[ -n "$RALPHY_PID" ]]; then
    local all_descendants=$(get_all_descendants "$RALPHY_PID")
    if [[ -n "$all_descendants" ]]; then
      for pid in $all_descendants; do
        local cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
        if [[ "$cmdline" == *"tsc"*"${worktree_dir}"* ]] || [[ "$cmdline" == *"eslint"*"${worktree_dir}"* ]]; then
          kill -TERM "$pid" 2>/dev/null || true
        fi
      done
    fi
  fi

  # Don't delete branch - it may have commits we want to keep/PR
}

# Run a single agent in its own isolated worktree
run_parallel_agent() {
  local task_name="$1"
  local agent_num="$2"
  local output_file="$3"
  local status_file="$4"
  local log_file="$5"

  echo "setting up" > "$status_file"

  # Update project board: task starting (parallel agent)
  if [[ "$PRD_SOURCE" == "github" ]]; then
    project_board_task_started "$task_name"
  fi

  # Log setup info
  echo "Agent $agent_num starting for task: $task_name" >> "$log_file"
  echo "ORIGINAL_DIR=$ORIGINAL_DIR" >> "$log_file"
  echo "WORKTREE_BASE=$WORKTREE_BASE" >> "$log_file"
  echo "BASE_BRANCH=$BASE_BRANCH" >> "$log_file"

  # Create isolated worktree for this agent
  local issue_id="${task_name%%:*}"
  local worktree_info
  worktree_info=$(create_agent_worktree "$task_name" "$agent_num" "$issue_id" 2>>"$log_file")
  local worktree_dir="${worktree_info%%|*}"
  local branch_name="${worktree_info##*|}"

  echo "Worktree dir: $worktree_dir" >> "$log_file"
  echo "Branch name: $branch_name" >> "$log_file"

  if [[ ! -d "$worktree_dir" ]]; then
    echo "failed" > "$status_file"
    echo "ERROR: Worktree directory does not exist: $worktree_dir" >> "$log_file"
    echo "0 0" > "$output_file"
    return 1
  fi

  local worktree_start_head=""
  worktree_start_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || echo "")
  local worktree_start_status=""
  worktree_start_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || echo "")

  echo "running" > "$status_file"

  # Copy PRD file to worktree from original directory
  if [[ "$PRD_SOURCE" == "markdown" ]] || [[ "$PRD_SOURCE" == "yaml" ]]; then
    cp "$ORIGINAL_DIR/$PRD_FILE" "$worktree_dir/" 2>/dev/null || true
  fi

  # Ensure progress.txt exists in worktree
  touch "$worktree_dir/progress.txt"

  # Copy repo-specific lessons file to worktree (if it exists)
  if [[ -f "$ORIGINAL_DIR/RALPHY_LESSONS.md" ]]; then
    cp "$ORIGINAL_DIR/RALPHY_LESSONS.md" "$worktree_dir/" 2>/dev/null || true
  fi

  # Build prompt for this specific task
  local lessons_ref=""
  if [[ -f "$worktree_dir/RALPHY_LESSONS.md" ]]; then
    lessons_ref="
BEFORE STARTING: Read @RALPHY_LESSONS.md for repo-specific rules and past mistakes. Follow all rules in that file."
  fi

  local prompt="You are working on a specific task. Focus ONLY on this task:

TASK: $task_name
${lessons_ref}

Instructions:
1. Implement this specific task completely
2. Write tests if appropriate
3. Update progress.txt with what you did
4. Commit your changes with a descriptive message
5. IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
   If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.

SCOPE RULES (MANDATORY):
- ONLY modify files directly required by this task.
- Do NOT refactor, rename, delete, or 'clean up' code outside the task scope.
- Do NOT remove imports, files, or utilities used by other parts of the codebase.
- Do NOT undo or revert changes from other issues/PRs.
- If you think something outside scope needs changing, note it in progress.txt but do NOT change it.
- Other agents are working on other tasks in parallel. Their work must not be disrupted.

LEARNINGS: If you discover a new pattern, pitfall, or rule specific to this repo, append it to RALPHY_LESSONS.md under 'Agent Learnings' before committing.

Do NOT modify PRD.md or mark tasks complete - that will be handled separately.
Focus only on implementing: $task_name"

  # Temp file for AI output
  local tmpfile
  tmpfile=$(mktemp)

  # Run AI agent in the worktree directory
  local result=""
  local success=false
  local retry=0

  while [[ $retry -lt $MAX_RETRIES ]]; do
    case "$AI_ENGINE" in
      opencode)
        (
          cd "$worktree_dir"
          OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
            --format json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      cursor)
        (
          cd "$worktree_dir"
          agent --print --force \
            --output-format stream-json \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      qwen)
        (
          cd "$worktree_dir"
          qwen --output-format stream-json \
            --approval-mode yolo \
            -p "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      codex)
        (
          cd "$worktree_dir"
          CODEX_LAST_MESSAGE_FILE="$tmpfile.last"
          rm -f "$CODEX_LAST_MESSAGE_FILE"
          codex exec --full-auto \
            --json \
            --output-last-message "$CODEX_LAST_MESSAGE_FILE" \
            "$prompt"
        ) > "$tmpfile" 2>>"$log_file"
        ;;
      *)
        (
          cd "$worktree_dir"
          claude --dangerously-skip-permissions \
            --verbose \
            -p "$prompt" \
            --output-format stream-json
        ) > "$tmpfile" 2>>"$log_file"
        ;;
    esac

    result=$(cat "$tmpfile" 2>/dev/null || echo "")

    if [[ -n "$result" ]]; then
      local error_msg
      if ! error_msg=$(check_for_errors "$result"); then
        ((retry++))
        echo "API error: $error_msg (attempt $retry/$MAX_RETRIES)" >> "$log_file"
        sleep "$RETRY_DELAY"
        continue
      fi
      local repo_changed=false
      if has_repo_changes_since "$worktree_start_head" "$worktree_start_status" "$worktree_dir"; then
        repo_changed=true
      fi
      if [[ "$result" == *"TOOL_ACCESS_FAILED"* ]]; then
        echo "ERROR: Tool access failed; no tools available." >> "$log_file"
        break
      fi
      if ! has_tool_usage "$result" && [[ "$repo_changed" != true ]]; then
        echo "ERROR: No tool usage detected; treating task as failed." >> "$log_file"
        break
      fi
      success=true
      break
    fi

    ((retry++))
    echo "Retry $retry/$MAX_RETRIES after empty response" >> "$log_file"
    sleep "$RETRY_DELAY"
  done

  rm -f "$tmpfile"

  if [[ "$success" == true ]]; then
    # Parse tokens
    local parsed input_tokens output_tokens
    local CODEX_LAST_MESSAGE_FILE="${tmpfile}.last"
    parsed=$(parse_ai_result "$result")
    local token_data
    token_data=$(echo "$parsed" | sed -n '/^---TOKENS---$/,$p' | tail -3)
    input_tokens=$(echo "$token_data" | sed -n '1p')
    output_tokens=$(echo "$token_data" | sed -n '2p')
    [[ "$input_tokens" =~ ^[0-9]+$ ]] || input_tokens=0
    [[ "$output_tokens" =~ ^[0-9]+$ ]] || output_tokens=0
    rm -f "${tmpfile}.last"

    # Check if this issue allows closing without code changes
    local no_code_ok=false
    if [[ "$PRD_SOURCE" == "github" ]] && issue_allows_no_code "$task_name"; then
      no_code_ok=true
      echo "Issue has no-code-required label; documentation/decision changes are acceptable" >> "$log_file"
    fi

    # Ensure at least one commit exists before marking success
    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_BRANCH"..HEAD 2>/dev/null || echo "0")
    [[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
    if [[ "$commit_count" -eq 0 ]] && [[ "$no_code_ok" != true ]]; then
      echo "ERROR: No new commits created; treating task as failed." >> "$log_file"
      echo "blocked:No commits created" > "$status_file"
      echo "0 0" > "$output_file"
      cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
      return 1
    fi
    if ! has_code_changes_between "$BASE_BRANCH" "HEAD" "$worktree_dir"; then
      if [[ "$no_code_ok" == true ]]; then
        echo "No code changes but issue allows it (decision/docs/chore)" >> "$log_file"
      else
        echo "ERROR: No code changes detected (only progress.txt); treating task as failed." >> "$log_file"
        echo "Tip: Add 'no-code-required', 'chore', 'documentation', or 'decision' label to allow closing without code" >> "$log_file"
        echo "blocked:No code changes detected" > "$status_file"
        echo "0 0" > "$output_file"
        cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
        return 1
      fi
    fi

    # Create PR if requested
    if [[ "$CREATE_PR" == true ]]; then
      (
        cd "$worktree_dir"
        git push -u origin "$branch_name" 2>>"$log_file" || true
        gh pr create \
          --base "$BASE_BRANCH" \
          --head "$branch_name" \
          --title "$task_name" \
          --body "Automated implementation by Ralphy (Agent $agent_num)" \
          ${PR_DRAFT:+--draft} 2>>"$log_file" || true
      )
      # Update project board to "In Review"
      if [[ "$PRD_SOURCE" == "github" ]]; then
        project_board_task_in_review "$task_name" "$branch_name"
      fi
    fi

    # Capture summary info before cleanup
    local commits_summary=""
    commits_summary=$(git -C "$worktree_dir" log --oneline "$BASE_BRANCH"..HEAD 2>/dev/null | head -10)
    local files_changed=""
    files_changed=$(git -C "$worktree_dir" diff --stat "$BASE_BRANCH"..HEAD 2>/dev/null | tail -10)

    # Write success output with summary
    echo "done" > "$status_file"
    {
      echo "$input_tokens $output_tokens $branch_name"
      echo "---COMMITS---"
      echo "$commits_summary"
      echo "---FILES---"
      echo "$files_changed"
    } > "$output_file"

    # Extract learnings from agent worktree before cleanup
    guardrail_merge_lessons "$worktree_dir" "$ORIGINAL_DIR" 2>/dev/null || true

    # Cleanup worktree (but keep branch)
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"

    return 0
  else
    echo "failed" > "$status_file"
    echo "0 0" > "$output_file"
    cleanup_agent_worktree "$worktree_dir" "$branch_name" "$log_file"
    return 1
  fi
}

# ============================================
# AUTO-PARALLEL EXECUTION (Sliding Window)
# ============================================

# Run tasks with a sliding window: as soon as any agent finishes,
# immediately start the next compatible task. No waiting for a full batch.
# Returns: 0=success, 1=some failed, 2=all complete/no tasks
run_auto_parallel_batch() {
  # Get all available (unclaimed) tasks
  local all_tasks=()
  while IFS= read -r task; do
    [[ -z "$task" ]] && continue
    local issue_num="${task%%:*}"
    if is_issue_claimed "$issue_num"; then
      log_debug "Skipping issue $issue_num (claimed by another instance)"
      continue
    fi
    all_tasks+=("$task")
  done < <(get_all_tasks)

  local total_tasks=${#all_tasks[@]}
  [[ $total_tasks -eq 0 ]] && return 2

  # Setup worktree infrastructure
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  guardrail_validate_base_branch
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT GITHUB_REPO GITHUB_LABEL

  # Pre-compute domains for all tasks (avoids repeated API calls)
  local -a task_domains=()
  for task in "${all_tasks[@]}"; do
    local t_title="${task#*:}"
    local t_body="" t_labels=""
    if [[ "$PRD_SOURCE" == "github" ]]; then
      t_body=$(get_github_issue_body "$task" 2>/dev/null || echo "")
      t_labels=$(get_github_issue_labels "$task" 2>/dev/null || echo "")
    fi
    task_domains+=("$(get_issue_domain "$t_title" "$t_body" "$t_labels")")
  done

  # Track which tasks have been started (by index into all_tasks)
  local -a task_started=()
  for ((i=0; i<total_tasks; i++)); do task_started+=(""); done

  # Sliding window: fixed-size slot arrays (empty pid = free slot)
  local -a sw_pids=() sw_tasks=() sw_domains=()
  local -a sw_status_files=() sw_output_files=() sw_log_files=() sw_agent_nums=()
  for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
    sw_pids+=("") sw_tasks+=("") sw_domains+=("")
    sw_status_files+=("") sw_output_files+=("") sw_log_files+=("") sw_agent_nums+=("")
  done

  local sw_active=0 sw_started=0 sw_done=0 sw_failed=0
  local sw_any_failed=false
  local sw_start_time=$SECONDS

  # Display header
  echo ""
  echo "${BOLD}>>> Sliding window${RESET} ${GREEN}(up to $AUTO_PARALLEL_MAX concurrent, $total_tasks tasks queued)${RESET}"
  echo ""

  # --- Fill initial slots ---
  for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
    # Find next compatible task
    local found_idx=""
    for ((t=0; t<total_tasks; t++)); do
      [[ -n "${task_started[$t]}" ]] && continue
      local candidate_domain="${task_domains[$t]}"
      local compatible=true
      for ((s2=0; s2<AUTO_PARALLEL_MAX; s2++)); do
        [[ -z "${sw_pids[$s2]}" ]] && continue
        if ! are_domains_compatible "$candidate_domain" "${sw_domains[$s2]}"; then
          compatible=false
          break
        fi
      done
      if [[ "$compatible" == true ]]; then
        found_idx="$t"
        break
      fi
    done

    [[ -z "$found_idx" ]] && break

    # Start task in this slot
    local task="${all_tasks[$found_idx]}"
    local domain="${task_domains[$found_idx]}"
    local issue_num="${task%%:*}"
    task_started[$found_idx]="true"
    ((iteration++))
    ((sw_started++))
    claim_issue "$issue_num"
    auto_label_docs_issue "$task"

    if [[ "$PRD_SOURCE" == "github" ]]; then
      project_board_task_started "$task"
    fi

    local status_file=$(mktemp) output_file=$(mktemp) log_file=$(mktemp)
    echo "waiting" > "$status_file"

    sw_tasks[$s]="$task"
    sw_domains[$s]="$domain"
    sw_status_files[$s]="$status_file"
    sw_output_files[$s]="$output_file"
    sw_log_files[$s]="$log_file"
    sw_agent_nums[$s]="$iteration"

    ( run_parallel_agent "$task" "$iteration" "$output_file" "$status_file" "$log_file" ) &
    sw_pids[$s]=$!
    ((sw_active++))

    printf "  ${CYAN}▶${RESET} Agent %d: %s ${DIM}(%s)${RESET}\n" "$iteration" "${task:0:55}" "$domain"
  done

  # --- Sliding window loop ---
  local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0
  local stuck_warned=false
  local PARALLEL_TIMEOUT_SECS=1800  # 30 minutes max
  local STUCK_WARNING_SECS=900      # Warn after 15 minutes
  local last_status_print=0         # Timestamp of last newline status print
  local STATUS_PRINT_INTERVAL=30    # Print a persistent status line every 30s

  while [[ $sw_active -gt 0 ]]; do
    # Check each slot for completion
    for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
      [[ -z "${sw_pids[$s]}" ]] && continue

      # Is this agent still running?
      if kill -0 "${sw_pids[$s]}" 2>/dev/null; then
        continue
      fi

      # --- Agent in slot $s completed ---
      wait "${sw_pids[$s]}" 2>/dev/null || true
      ((sw_active--))

      local task="${sw_tasks[$s]}"
      local issue_num="${task%%:*}"
      local agent_num="${sw_agent_nums[$s]}"
      local status=$(cat "${sw_status_files[$s]}" 2>/dev/null || echo "unknown")

      local icon color
      case "$status" in
        done)
          icon="✓" color="$GREEN"
          ((sw_done++))
          ((session_processed++))
          notify_task_done "#${issue_num}: ${task#*:}"

          local output_content=$(cat "${sw_output_files[$s]}" 2>/dev/null || echo "0 0 unknown")
          local first_line=$(echo "$output_content" | head -1)
          local in_tok=$(echo "$first_line" | awk '{print $1}')
          local out_tok=$(echo "$first_line" | awk '{print $2}')
          local branch=$(echo "$first_line" | awk '{print $3}')
          local commits_section=$(echo "$output_content" | sed -n '/---COMMITS---/,/---FILES---/p' | grep -v '^---')
          local files_section=$(echo "$output_content" | sed -n '/---FILES---/,$ p' | grep -v '^---')
          [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
          [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
          total_input_tokens=$((total_input_tokens + in_tok))
          total_output_tokens=$((total_output_tokens + out_tok))

          if [[ "$PRD_SOURCE" == "markdown" ]]; then
            mark_task_complete_markdown "$task"
          elif [[ "$PRD_SOURCE" == "yaml" ]]; then
            mark_task_complete_yaml "$task"
          elif [[ "$PRD_SOURCE" == "github" ]]; then
            local comment="## Task Completed by Ralphy (Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

### Commits
\`\`\`
${commits_section:-No commits captured}
\`\`\`

### Files Changed
\`\`\`
${files_section:-No file changes captured}
\`\`\`"
            mark_task_complete_github "$task" "$comment"
            project_board_task_completed "$task" "$branch"
          fi

          # Merge agent branch back into base branch (skip if PRs are being created)
          if [[ "$CREATE_PR" != true ]] && [[ -n "$branch" ]] && [[ "$branch" != "unknown" ]]; then
            if git -C "$ORIGINAL_DIR" merge --no-edit "$branch" >/dev/null 2>&1; then
              log_debug "Merged $branch into $BASE_BRANCH"
              # Verify merge actually landed commits before deleting branch
              if guardrail_verify_merge "$branch" "$ORIGINAL_DIR"; then
                git -C "$ORIGINAL_DIR" branch -d "$branch" >/dev/null 2>&1 || true
              else
                log_warn "Merge verification failed for $branch — branch preserved"
              fi
            else
              log_warn "Merge conflict merging $branch into $BASE_BRANCH — aborting merge, branch preserved for manual resolution"
              git -C "$ORIGINAL_DIR" merge --abort 2>/dev/null || true
              guardrail_update_branch "$branch" "failed"
            fi
          fi
          ;;
        blocked:*)
          icon="⊘" color="$YELLOW"
          ((sw_failed++))
          local reason="${status#blocked:}"
          mark_issue_blocked "$task" "$reason"
          ;;
        failed)
          icon="✗" color="$RED"
          ((sw_failed++))
          sw_any_failed=true
          notify_error "Issue #${issue_num} failed: ${task#*:}"
          ;;
        *)
          icon="?" color="$YELLOW"
          ((sw_failed++))
          ;;
      esac

      # Clear spinner line, print result, then spinner resumes
      printf "\r%80s\r" ""
      printf "  ${color}%s${RESET} Agent %d: %s\n" "$icon" "$agent_num" "${task:0:55}"

      if [[ "$status" == "failed" ]] && [[ -s "${sw_log_files[$s]}" ]]; then
        echo "${DIM}    └─ $(tail -1 "${sw_log_files[$s]}")${RESET}"
      fi

      release_issue "$issue_num"
      rm -f "${sw_status_files[$s]}" "${sw_output_files[$s]}" "${sw_log_files[$s]}"

      # Free the slot
      sw_pids[$s]=""
      sw_tasks[$s]=""
      sw_domains[$s]=""

      # --- Try to fill this slot with the next compatible task ---
      local found_idx=""
      for ((t=0; t<total_tasks; t++)); do
        [[ -n "${task_started[$t]}" ]] && continue
        local candidate_domain="${task_domains[$t]}"
        local compatible=true
        for ((s2=0; s2<AUTO_PARALLEL_MAX; s2++)); do
          [[ -z "${sw_pids[$s2]}" ]] && continue
          if ! are_domains_compatible "$candidate_domain" "${sw_domains[$s2]}"; then
            compatible=false
            break
          fi
        done
        if [[ "$compatible" == true ]]; then
          found_idx="$t"
          break
        fi
      done

      if [[ -n "$found_idx" ]]; then
        local next_task="${all_tasks[$found_idx]}"
        local next_domain="${task_domains[$found_idx]}"
        local next_issue="${next_task%%:*}"
        task_started[$found_idx]="true"
        ((iteration++))
        ((sw_started++))
        claim_issue "$next_issue"
        auto_label_docs_issue "$next_task"

        if [[ "$PRD_SOURCE" == "github" ]]; then
          project_board_task_started "$next_task"
        fi

        local new_sf=$(mktemp) new_of=$(mktemp) new_lf=$(mktemp)
        echo "waiting" > "$new_sf"

        sw_tasks[$s]="$next_task"
        sw_domains[$s]="$next_domain"
        sw_status_files[$s]="$new_sf"
        sw_output_files[$s]="$new_of"
        sw_log_files[$s]="$new_lf"
        sw_agent_nums[$s]="$iteration"

        ( run_parallel_agent "$next_task" "$iteration" "$new_of" "$new_sf" "$new_lf" ) &
        sw_pids[$s]=$!
        ((sw_active++))

        printf "  ${CYAN}▶${RESET} Agent %d: %s ${DIM}(%s)${RESET}\n" "$iteration" "${next_task:0:55}" "$next_domain"
      fi
    done

    # Exit if nothing running
    [[ $sw_active -eq 0 ]] && break

    local elapsed=$(( SECONDS - sw_start_time ))

    # Stuck detection
    if [[ $elapsed -ge $STUCK_WARNING_SECS ]] && [[ "$stuck_warned" == false ]]; then
      stuck_warned=true
      local stuck_tasks=""
      for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
        [[ -z "${sw_pids[$s]}" ]] && continue
        stuck_tasks+="${sw_tasks[$s]:0:50} "
      done
      notify_task_stuck "$stuck_tasks" "$((elapsed / 60))"
      log_warn "Agents running for ${elapsed}s — may be stuck: $stuck_tasks"
    fi

    # Hard timeout
    if [[ $elapsed -ge $PARALLEL_TIMEOUT_SECS ]]; then
      log_error "Sliding window timed out after $((elapsed / 60))m — killing remaining agents"
      notify_error "Timed out after $((elapsed / 60))m"
      for ((s=0; s<AUTO_PARALLEL_MAX; s++)); do
        [[ -z "${sw_pids[$s]}" ]] && continue
        kill "${sw_pids[$s]}" 2>/dev/null || true
        echo "failed" > "${sw_status_files[$s]}"
        wait "${sw_pids[$s]}" 2>/dev/null || true
        ((sw_active--))
        ((sw_failed++))
        local t_task="${sw_tasks[$s]}"
        local t_issue="${t_task%%:*}"
        printf "  ${RED}✗${RESET} Agent %d: %s ${DIM}(timed out)${RESET}\n" "${sw_agent_nums[$s]}" "${t_task:0:55}"
        release_issue "$t_issue"
        rm -f "${sw_status_files[$s]}" "${sw_output_files[$s]}" "${sw_log_files[$s]}"
        sw_pids[$s]=""
      done
      break
    fi

    # Update spinner
    local spin_char="${spinner_chars:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))
    local queued=$(( total_tasks - sw_started ))
    [[ $queued -lt 0 ]] && queued=0

    # Periodic persistent status line (newline-based, can't be clobbered)
    if [[ $((elapsed - last_status_print)) -ge $STATUS_PRINT_INTERVAL ]]; then
      last_status_print=$elapsed
      printf "\r%80s\r" ""
      printf "  ${DIM}[%02d:%02d]${RESET} Running: ${CYAN}%d${RESET} | Done: ${GREEN}%d${RESET} | Failed: ${RED}%d${RESET} | Queued: %d\n" \
        $((elapsed / 60)) $((elapsed % 60)) "$sw_active" "$sw_done" "$sw_failed" "$queued"
    fi

    # In-place spinner (fast update between persistent lines)
    printf "\r  ${CYAN}%s${RESET} Running: %d | Done: %d | Failed: %d | Queued: %d | %02d:%02d " \
      "$spin_char" "$sw_active" "$sw_done" "$sw_failed" "$queued" \
      $((elapsed / 60)) $((elapsed % 60))

    sleep 0.3
  done

  printf "\r%80s\r" ""  # Clear spinner line

  # Cleanup worktree base
  if [[ -d "$WORKTREE_BASE" ]]; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  fi

  # Summary line
  echo ""
  echo "${BOLD}Window complete:${RESET} ${GREEN}$sw_done done${RESET} | ${RED}$sw_failed failed${RESET} | $total_tasks total"

  # Check remaining tasks
  local remaining
  remaining=$(count_remaining_tasks | tr -d '[:space:]')
  remaining=${remaining:-0}
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0

  if [[ "$remaining" -eq 0 ]]; then
    return 2  # All complete
  fi

  [[ "$sw_any_failed" == true ]] && return 1
  return 0
}
run_parallel_tasks() {
  log_info "Running ${BOLD}$MAX_PARALLEL parallel agents${RESET} (each in isolated worktree)..."

  local all_tasks=()

  # Get all pending tasks
  while IFS= read -r task; do
    [[ -n "$task" ]] && all_tasks+=("$task")
  done < <(get_all_tasks)

  if [[ ${#all_tasks[@]} -eq 0 ]]; then
    log_info "No tasks to run"
    return 2
  fi

  local total_tasks=${#all_tasks[@]}
  log_info "Found $total_tasks tasks to process"

  # Store original directory for git operations from subshells
  ORIGINAL_DIR=$(pwd)
  export ORIGINAL_DIR

  # Set up worktree base directory
  WORKTREE_BASE=$(mktemp -d)
  export WORKTREE_BASE
  log_debug "Worktree base: $WORKTREE_BASE"

  # Ensure we have a base branch set
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  fi
  export BASE_BRANCH
  guardrail_validate_base_branch
  log_info "Base branch: $BASE_BRANCH"

  # Export variables needed by subshell agents
  export AI_ENGINE MAX_RETRIES RETRY_DELAY PRD_SOURCE PRD_FILE CREATE_PR PR_DRAFT

  local batch_num=0
  local completed_branches=()
  local any_failed=false
  local groups=("all")

  if [[ "$PRD_SOURCE" == "yaml" ]]; then
    groups=()
    while IFS= read -r group; do
      [[ -n "$group" ]] && groups+=("$group")
    done < <(yq -r '.tasks[] | select(.completed != true) | (.parallel_group // 0)' "$PRD_FILE" 2>/dev/null | sort -n | uniq)
  fi

  for group in "${groups[@]}"; do
    local tasks=()
    local group_label=""

    if [[ "$PRD_SOURCE" == "yaml" ]]; then
      while IFS= read -r task; do
        [[ -n "$task" ]] && tasks+=("$task")
      done < <(get_tasks_in_group_yaml "$group")
      [[ ${#tasks[@]} -eq 0 ]] && continue
      group_label=" (group $group)"
    else
      tasks=("${all_tasks[@]}")
    fi

    local batch_start=0
    local total_group_tasks=${#tasks[@]}

    while [[ $batch_start -lt $total_group_tasks ]]; do
      ((batch_num++))
      local batch_end=$((batch_start + MAX_PARALLEL))
      [[ $batch_end -gt $total_group_tasks ]] && batch_end=$total_group_tasks
      local batch_size=$((batch_end - batch_start))

      echo ""
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo "${BOLD}Batch $batch_num${group_label}: Spawning $batch_size parallel agents${RESET}"
      echo "${DIM}Each agent runs in its own git worktree with isolated workspace${RESET}"
      echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
      echo ""

      # Setup arrays for this batch
      parallel_pids=()
      local batch_tasks=()
      local status_files=()
      local output_files=()
      local log_files=()

      # Start all agents in the batch
      for ((i = batch_start; i < batch_end; i++)); do
        local task="${tasks[$i]}"
        local agent_num=$((iteration + 1))
        ((iteration++))

        local status_file=$(mktemp)
        local output_file=$(mktemp)
        local log_file=$(mktemp)

        batch_tasks+=("$task")
        status_files+=("$status_file")
        output_files+=("$output_file")
        log_files+=("$log_file")

        echo "waiting" > "$status_file"

        # Show initial status
        printf "  ${CYAN}◉${RESET} Agent %d: %s
" "$agent_num" "${task:0:50}"

        # Run agent in background
        (
          run_parallel_agent "$task" "$agent_num" "$output_file" "$status_file" "$log_file"
        ) &
        parallel_pids+=($!)
      done

      echo ""

      # Monitor progress with a spinner
      local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
      local spin_idx=0
      local start_time=$SECONDS

      while true; do
        # Check if all processes are done
        local all_done=true
        local setting_up=0
        local running=0
        local done_count=0
        local failed_count=0

        for ((j = 0; j < batch_size; j++)); do
          local pid="${parallel_pids[$j]}"
          local status_file="${status_files[$j]}"
          local status=$(cat "$status_file" 2>/dev/null || echo "waiting")

          case "$status" in
            "setting up")
              all_done=false
              ((setting_up++))
              ;;
            running)
              all_done=false
              ((running++))
              ;;
            done)
              ((done_count++))
              ;;
            failed)
              ((failed_count++))
              ;;
            *)
              # Check if process is still running
              if kill -0 "$pid" 2>/dev/null; then
                all_done=false
              fi
              ;;
          esac
        done

        [[ "$all_done" == true ]] && break

        # Update spinner
        local elapsed=$((SECONDS - start_time))
        local spin_char="${spinner_chars:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner_chars} ))

        printf "  ${CYAN}%s${RESET} Agents: ${BLUE}%d setup${RESET} | ${YELLOW}%d running${RESET} | ${GREEN}%d done${RESET} | ${RED}%d failed${RESET} | %02d:%02d " \
          "$spin_char" "$setting_up" "$running" "$done_count" "$failed_count" $((elapsed / 60)) $((elapsed % 60))

        sleep 0.3
      done

      # Clear the spinner line
      printf "%100s" ""

      # Wait for all processes to fully complete
      for pid in "${parallel_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done

      # Show final status for this batch
      echo ""
      echo "${BOLD}Batch $batch_num Results:${RESET}"
      for ((j = 0; j < batch_size; j++)); do
        local task="${batch_tasks[$j]}"
        local status_file="${status_files[$j]}"
        local output_file="${output_files[$j]}"
        local log_file="${log_files[$j]}"
        local status=$(cat "$status_file" 2>/dev/null || echo "unknown")
        local agent_num=$((iteration - batch_size + j + 1))

        local icon color branch_info=""
        case "$status" in
          done)
            icon="✓"
            color="$GREEN"
            ((session_processed++))
            # Collect tokens and branch name
            local output_data=$(cat "$output_file" 2>/dev/null || echo "0 0")
            local in_tok=$(echo "$output_data" | awk '{print $1}')
            local out_tok=$(echo "$output_data" | awk '{print $2}')
            local branch=$(echo "$output_data" | awk '{print $3}')
            [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
            [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
            total_input_tokens=$((total_input_tokens + in_tok))
            total_output_tokens=$((total_output_tokens + out_tok))
            if [[ -n "$branch" ]]; then
              completed_branches+=("$branch")
              branch_info=" → ${CYAN}$branch${RESET}"
            fi

            # Mark task complete in PRD
            if [[ "$PRD_SOURCE" == "markdown" ]]; then
              mark_task_complete_markdown "$task"
            elif [[ "$PRD_SOURCE" == "yaml" ]]; then
              mark_task_complete_yaml "$task"
            elif [[ "$PRD_SOURCE" == "github" ]]; then
              # Build completion comment for parallel agent
              local parallel_comment="## Task Completed by Ralphy (Parallel Agent $agent_num)

**Branch:** \`$branch\`
**Engine:** ${AI_ENGINE}

Implementation completed successfully. See branch for commit details."
              mark_task_complete_github "$task" "$parallel_comment"
              project_board_task_completed "$task" "$branch"
            fi
            ;;
          blocked:*)
            icon="⊘"
            color="$YELLOW"
            local block_reason="${status#blocked:}"
            mark_issue_blocked "$task" "$block_reason"
            branch_info=" ${DIM}(blocked)${RESET}"
            ;;
          failed)
            icon="✗"
            color="$RED"
            any_failed=true
            if [[ -s "$log_file" ]]; then
              branch_info=" ${DIM}(error below)${RESET}"
            fi
            ;;
          *)
            icon="?"
            color="$YELLOW"
            ;;
        esac

        printf "  ${color}%s${RESET} Agent %d: %s%s
" "$icon" "$agent_num" "${task:0:45}" "$branch_info"

        # Show log for failed agents
        if [[ "$status" == "failed" ]] && [[ -s "$log_file" ]]; then
          echo "${DIM}    ┌─ Agent $agent_num log:${RESET}"
          sed 's/^/    │ /' "$log_file" | head -20
          local log_lines=$(wc -l < "$log_file")
          if [[ $log_lines -gt 20 ]]; then
            echo "${DIM}    │ ... ($((log_lines - 20)) more lines)${RESET}"
          fi
          echo "${DIM}    └─${RESET}"
        fi

        # Cleanup temp files
        rm -f "$status_file" "$output_file" "$log_file"
      done

      batch_start=$batch_end

      # Check if we've hit max iterations
      if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log_warn "Reached max iterations ($MAX_ITERATIONS)"
        break
      fi
    done

    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      break
    fi
  done

  # Cleanup worktree base
  if ! find "$WORKTREE_BASE" -maxdepth 1 -type d -name 'agent-*' -print -quit 2>/dev/null | grep -q .; then
    rm -rf "$WORKTREE_BASE" 2>/dev/null || true
  else
    log_warn "Preserving worktree base with dirty agents: $WORKTREE_BASE"
  fi

  # Handle completed branches
  if [[ ${#completed_branches[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

    if [[ "$CREATE_PR" == true ]]; then
      # PRs were created, just show the branches
      echo "${BOLD}Branches created by agents:${RESET}"
      for branch in "${completed_branches[@]}"; do
        echo "  ${CYAN}•${RESET} $branch"
      done
    else
      # Auto-merge branches back to main
      echo "${BOLD}Merging agent branches into ${BASE_BRANCH}...${RESET}"
      echo ""

      if ! git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        log_warn "Could not checkout $BASE_BRANCH; leaving agent branches unmerged."
        echo "${BOLD}Branches created by agents:${RESET}"
        for branch in "${completed_branches[@]}"; do
          echo "  ${CYAN}•${RESET} $branch"
        done
        return 0
      fi

      local merge_failed=()

      for branch in "${completed_branches[@]}"; do
        printf "  Merging ${CYAN}%s${RESET}..." "$branch"

        # Attempt to merge
        if git merge --no-edit "$branch" >/dev/null 2>&1; then
          # Verify merge actually landed commits before deleting branch
          if guardrail_verify_merge "$branch"; then
            printf " ${GREEN}✓${RESET}
"
            git branch -d "$branch" >/dev/null 2>&1 || true
          else
            printf " ${YELLOW}merge verified failed${RESET}
"
            log_warn "Merge verification failed for $branch — branch preserved"
          fi
        else
          printf " ${YELLOW}conflict${RESET}"
          merge_failed+=("$branch")
          guardrail_update_branch "$branch" "failed"
          # Don't abort yet - try AI resolution
        fi
      done

      # Use AI to resolve merge conflicts
      if [[ ${#merge_failed[@]} -gt 0 ]]; then
        echo ""
        echo "${BOLD}Using AI to resolve ${#merge_failed[@]} merge conflict(s)...${RESET}"
        echo ""

        local still_failed=()

        for branch in "${merge_failed[@]}"; do
          printf "  Resolving ${CYAN}%s${RESET}..." "$branch"

          # Get list of conflicted files
          local conflicted_files
          conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

          if [[ -z "$conflicted_files" ]]; then
            # No conflicts found (maybe already resolved or aborted)
            git merge --abort 2>/dev/null || true
            git merge --no-edit "$branch" >/dev/null 2>&1 || {
              printf " ${RED}✗${RESET}
"
              still_failed+=("$branch")
              guardrail_update_branch "$branch" "failed"
              git merge --abort 2>/dev/null || true
              continue
            }
            if guardrail_verify_merge "$branch"; then
              printf " ${GREEN}✓${RESET}
"
              git branch -d "$branch" >/dev/null 2>&1 || true
            else
              printf " ${YELLOW}verify failed${RESET}
"
            fi
            continue
          fi

          # Build prompt for AI to resolve conflicts
          local resolve_prompt="You are resolving a git merge conflict. The following files have conflicts:

$conflicted_files

For each conflicted file:
1. Read the file to see the conflict markers (<<<<<<< HEAD, =======, >>>>>>> branch)
2. Understand what both versions are trying to do
3. Edit the file to resolve the conflict by combining both changes intelligently
4. Remove all conflict markers
5. Make sure the resulting code is valid and compiles

After resolving all conflicts:
1. Run 'git add' on each resolved file
2. Run 'git commit --no-edit' to complete the merge

Be careful to preserve functionality from BOTH branches. The goal is to integrate all features."

          # Run AI to resolve conflicts
          local resolve_tmpfile
          resolve_tmpfile=$(mktemp)

          case "$AI_ENGINE" in
            opencode)
              OPENCODE_PERMISSION='{"*":"allow"}' opencode run \
                --format json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            cursor)
              agent --print --force \
                --output-format stream-json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            qwen)
              qwen --output-format stream-json \
                --approval-mode yolo \
                -p "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            codex)
              codex exec --full-auto \
                --json \
                "$resolve_prompt" > "$resolve_tmpfile" 2>&1
              ;;
            *)
              claude --dangerously-skip-permissions \
                -p "$resolve_prompt" \
                --output-format stream-json > "$resolve_tmpfile" 2>&1
              ;;
          esac

          rm -f "$resolve_tmpfile"

          # Check if merge was completed
          if ! git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            # No more conflicts - merge succeeded
            if guardrail_verify_merge "$branch"; then
              printf " ${GREEN}✓ (AI resolved)${RESET}
"
              git branch -d "$branch" >/dev/null 2>&1 || true
            else
              printf " ${YELLOW}✓ (AI resolved, verify failed — branch preserved)${RESET}
"
            fi
          else
            # Still has conflicts
            printf " ${RED}✗ (AI couldn't resolve)${RESET}
"
            still_failed+=("$branch")
            guardrail_update_branch "$branch" "failed"
            git merge --abort 2>/dev/null || true
          fi
        done

        if [[ ${#still_failed[@]} -gt 0 ]]; then
          echo ""
          echo "${YELLOW}Some conflicts could not be resolved automatically:${RESET}"
          for branch in "${still_failed[@]}"; do
            echo "  ${YELLOW}•${RESET} $branch"
          done
          echo ""
          echo "${DIM}Resolve conflicts manually: git merge <branch>${RESET}"
        else
          echo ""
          echo "${GREEN}All branches merged successfully!${RESET}"
        fi
      else
        echo ""
        echo "${GREEN}All branches merged successfully!${RESET}"
      fi
    fi
  fi

  if [[ "$any_failed" == true ]]; then
    return 1
  fi

  return 0
}
