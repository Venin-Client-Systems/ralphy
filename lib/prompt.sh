# ============================================
# PROMPT BUILDER
# ============================================

build_prompt() {
  local task_override="${1:-}"
  local prompt=""

  # Add context based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    yaml)
      prompt="@${PRD_FILE} @progress.txt"
      ;;
    github)
      # For GitHub issues, we include the issue body
      local issue_body=""
      if [[ -n "$task_override" ]]; then
        issue_body=$(get_github_issue_body "$task_override")
      fi
      prompt="Task from GitHub Issue: $task_override

Issue Description:
$issue_body

@progress.txt"
      ;;
  esac

  prompt="$prompt
IMPORTANT: You MUST use tools to read and edit files in this repo. Do not respond with a plan only.
If you cannot access tools or the repo, respond exactly with 'TOOL_ACCESS_FAILED'.
1. Find the highest-priority incomplete task and implement it."

  local step=2

  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt
$step. Write tests for the feature.
$((step+1)). Run tests and ensure they pass before proceeding."
    step=$((step+2))
  fi

  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt
$step. Run linting and ensure it passes before proceeding."
    step=$((step+1))
  fi

  # Adjust completion step based on PRD source
  case "$PRD_SOURCE" in
    markdown)
      prompt="$prompt
$step. Update the PRD to mark the task as complete (change '- [ ]' to '- [x]')."
      ;;
    yaml)
      prompt="$prompt
$step. Update ${PRD_FILE} to mark the task as completed (set completed: true)."
      ;;
    github)
      prompt="$prompt
$step. The task will be marked complete automatically. Just note the completion in progress.txt."
      ;;
  esac

  step=$((step+1))

  prompt="$prompt
$step. Append your progress to progress.txt.
$((step+1)). Commit your changes with a descriptive message.
ONLY WORK ON A SINGLE TASK."

  if [[ "$SKIP_TESTS" == false ]]; then
    prompt="$prompt Do not proceed if tests fail."
  fi
  if [[ "$SKIP_LINT" == false ]]; then
    prompt="$prompt Do not proceed if linting fails."
  fi

  prompt="$prompt
If ALL tasks in the PRD are complete, output <promise>COMPLETE</promise>."

  echo "$prompt"
}
