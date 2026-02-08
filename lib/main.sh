# ============================================
# MAIN
# ============================================

main() {
  parse_args "$@"
  init_fallback_engines

  if [[ "$DRY_RUN" == true ]] && [[ "$MAX_ITERATIONS" -eq 0 ]]; then
    MAX_ITERATIONS=1
  fi

  # Set up cleanup trap
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  # Check requirements
  check_requirements

  # Reap orphaned processes from previous sessions at startup
  reap_orphaned_processes

  # Initialize multi-instance coordination
  init_instance_lock

  # Initialize project board connection
  project_board_init

  # Show banner
  echo "${BOLD}============================================${RESET}"
  echo "${BOLD}Ralphy${RESET} - Running until PRD is complete"
  local engine_display
  engine_display=$(engine_display_name "$AI_ENGINE")
  echo "Engine: $engine_display"
  if [[ ${#FALLBACK_ENGINES[@]} -gt 0 ]]; then
    local fallback_display=""
    local fallback_engine
    for fallback_engine in "${FALLBACK_ENGINES[@]}"; do
      local label
      label=$(engine_display_name "$fallback_engine")
      if [[ -z "$fallback_display" ]]; then
        fallback_display="$label"
      else
        fallback_display="$fallback_display -> $label"
      fi
    done
    echo "Fallback: $fallback_display (on rate limit)"
  fi
  echo "Source: ${CYAN}$PRD_SOURCE${RESET} (${PRD_FILE:-$GITHUB_REPO})"

  local mode_parts=()
  [[ "$SKIP_TESTS" == true ]] && mode_parts+=("no-tests")
  [[ "$SKIP_LINT" == true ]] && mode_parts+=("no-lint")
  [[ "$DRY_RUN" == true ]] && mode_parts+=("dry-run")
  [[ "$PARALLEL" == true ]] && mode_parts+=("parallel:$MAX_PARALLEL")
  [[ "$AUTO_PARALLEL" == true ]] && [[ "$PARALLEL" != true ]] && mode_parts+=("auto-parallel:$AUTO_PARALLEL_MAX")
  [[ "$BRANCH_PER_TASK" == true ]] && mode_parts+=("branch-per-task")
  [[ "$CREATE_PR" == true ]] && mode_parts+=("create-pr")
  [[ -n "$PROJECT_NODE_ID" ]] && mode_parts+=("project-board")
  [[ $MAX_ITERATIONS -gt 0 ]] && mode_parts+=("max:$MAX_ITERATIONS")

  if [[ ${#mode_parts[@]} -gt 0 ]]; then
    echo "Mode: ${YELLOW}${mode_parts[*]}${RESET}"
  fi
  echo "${BOLD}============================================${RESET}"

  # Show other running instances
  show_instance_status

  # Run in parallel or sequential mode
  if [[ "$PARALLEL" == true ]]; then
    local parallel_code=0
    run_parallel_tasks || parallel_code=$?
    if [[ $parallel_code -eq 2 ]]; then
      show_summary
      notify_done
      exit 0
    fi
    if [[ $parallel_code -ne 0 ]]; then
      log_error "Parallel run failed; exiting."
      exit 1
    fi
    show_summary
    notify_done
    exit 0
  fi

  # Main loop - auto-parallel or sequential
  while true; do
    local result_code=0

    if [[ "$AUTO_PARALLEL" == true ]]; then
      # Smart auto-parallel: run 1-2 tasks based on domain detection
      run_auto_parallel_batch || result_code=$?

      case $result_code in
        0)
          # Success, continue
          ;;
        1)
          # Some tasks failed, but continue
          log_warn "Some tasks failed, continuing..."
          ;;
        2)
          # All tasks complete
          show_summary
          notify_done
          exit 0
          ;;
        3)
          # No real code changes detected - check for loop, then mark blocked
          if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
            if track_failed_task "$LAST_ATTEMPTED_TASK"; then
              # Loop detected - try to fix or exit
              if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
                show_summary
                notify_done "Ralphy stopped due to loop detection"
                exit 1
              fi
              # Loop was auto-fixed, continue
            else
              # Not a loop yet - mark blocked and continue
              mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No code changes detected (docs/progress only)"
              log_info "Continuing to next issue..."
            fi
          fi
          ;;
        4)
          # Tool usage required but missing - check for loop, then mark blocked
          if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
            if track_failed_task "$LAST_ATTEMPTED_TASK"; then
              if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
                show_summary
                notify_done "Ralphy stopped due to loop detection"
                exit 1
              fi
            else
              mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No tool usage detected"
              log_info "Continuing to next issue..."
            fi
          fi
          ;;
      esac
    else
      # Pure sequential mode - claim issue before starting
      ((++iteration))
      local next_task
      next_task=$(get_next_unclaimed_task)

      if [[ -n "$next_task" ]]; then
        local issue_num="${next_task%%:*}"
        claim_issue "$issue_num"
        # Pre-emptively label docs issues so they can close without code changes
        auto_label_docs_issue "$next_task"
      fi

      run_single_task "$next_task" "$iteration" || result_code=$?

      # Release the issue after completion
      if [[ -n "$LAST_ATTEMPTED_TASK" ]]; then
        local issue_num="${LAST_ATTEMPTED_TASK%%:*}"
        release_issue "$issue_num"
      fi

      case $result_code in
        0)
          # Success, continue
          ;;
        1)
          # Error, but continue to next task
          log_warn "Task failed after $MAX_RETRIES attempts, continuing..."
          ;;
        2)
          # All tasks complete
          show_summary
          notify_done
          exit 0
          ;;
        3)
          # No real code changes detected - check for loop, then mark blocked
          if track_failed_task "$LAST_ATTEMPTED_TASK"; then
            # Loop detected - try to fix or exit
            if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
              show_summary
              notify_done "Ralphy stopped due to loop detection"
              exit 1
            fi
            # Loop was auto-fixed, continue
          else
            # Not a loop yet - mark blocked and continue
            mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No code changes detected (docs/progress only)"
            log_info "Continuing to next issue..."
          fi
          ;;
        4)
          # Tool usage required but missing - check for loop, then mark blocked
          if track_failed_task "$LAST_ATTEMPTED_TASK"; then
            if ! handle_task_loop "$LAST_ATTEMPTED_TASK"; then
              show_summary
              notify_done "Ralphy stopped due to loop detection"
              exit 1
            fi
          else
            mark_issue_blocked "$LAST_ATTEMPTED_TASK" "No tool usage detected"
            log_info "Continuing to next issue..."
          fi
          ;;
      esac
    fi

    # Check max iterations
    if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $iteration -ge $MAX_ITERATIONS ]]; then
      log_warn "Reached max iterations ($MAX_ITERATIONS)"
      show_summary
      notify_done "Ralphy stopped after $MAX_ITERATIONS iterations"
      exit 0
    fi

    # Reap any orphaned processes between iterations
    reap_orphaned_processes

    # Small delay between iterations
    sleep 1
  done
}
