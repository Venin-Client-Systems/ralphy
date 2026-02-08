# ============================================
# SUMMARY
# ============================================

show_summary() {
  echo ""
  echo "${BOLD}============================================${RESET}"
  local blocked_count=${#blocked_issues[@]}
  if [[ $blocked_count -gt 0 ]]; then
    echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s), ${YELLOW}$blocked_count blocked${RESET}."
  else
    echo "${GREEN}PRD complete!${RESET} Finished $iteration task(s)."
  fi
  echo "${BOLD}============================================${RESET}"
  echo ""
  echo "${BOLD}>>> Usage Summary${RESET}"

  # Cursor doesn't provide token usage, but does provide duration
  if [[ "$AI_ENGINE" == "cursor" ]]; then
    echo "${DIM}Token usage not available (Cursor CLI doesn't expose this data)${RESET}"
    if [[ "$total_duration_ms" -gt 0 ]]; then
      local dur_sec=$((total_duration_ms / 1000))
      local dur_min=$((dur_sec / 60))
      local dur_sec_rem=$((dur_sec % 60))
      if [[ "$dur_min" -gt 0 ]]; then
        echo "Total API time: ${dur_min}m ${dur_sec_rem}s"
      else
        echo "Total API time: ${dur_sec}s"
      fi
    fi
  else
    echo "Input tokens:  $total_input_tokens"
    echo "Output tokens: $total_output_tokens"
    echo "Total tokens:  $((total_input_tokens + total_output_tokens))"

    # Show actual cost only for OpenCode (API-based, not subscription)
    if [[ "$AI_ENGINE" == "opencode" ]] && command -v bc &>/dev/null; then
      local has_actual_cost
      has_actual_cost=$(echo "$total_actual_cost > 0" | bc 2>/dev/null || echo "0")
      if [[ "$has_actual_cost" == "1" ]]; then
        echo "Actual cost:   \$${total_actual_cost}"
      fi
    fi
    # Claude Code is subscription-based, no per-token cost to display
  fi

  # Show branches if created
  if [[ -n "${task_branches[*]+"${task_branches[*]}"}" ]]; then
    echo ""
    echo "${BOLD}>>> Branches Created${RESET}"
    for branch in "${task_branches[@]}"; do
      echo "  - $branch"
    done
  fi

  # Show blocked issues if any
  if [[ ${#blocked_issues[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}>>> Blocked Issues (${#blocked_issues[@]})${RESET}"
    echo "${YELLOW}These issues need manual review:${RESET}"
    for i in "${!blocked_issues[@]}"; do
      local issue="${blocked_issues[$i]}"
      local reason="${blocked_reasons[$i]:-unknown}"
      echo "  ${RED}✗${RESET} $issue"
      echo "    ${DIM}Reason: $reason${RESET}"
    done
    echo ""
    echo "${DIM}To fix: Add 'chore', 'documentation', or 'no-code-required' label, then remove 'ralphy-blocked'${RESET}"
  fi

  echo "${BOLD}============================================${RESET}"
}
