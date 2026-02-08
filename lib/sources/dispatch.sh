# ============================================
# UNIFIED TASK INTERFACE
# ============================================

get_next_task() {
  case "$PRD_SOURCE" in
    markdown) get_next_task_markdown ;;
    yaml) get_next_task_yaml ;;
    github) get_next_task_github ;;
  esac
}

get_all_tasks() {
  case "$PRD_SOURCE" in
    markdown) get_tasks_markdown ;;
    yaml) get_tasks_yaml ;;
    github) get_tasks_github ;;
  esac
}

count_remaining_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_remaining_markdown ;;
    yaml) count_remaining_yaml ;;
    github) count_remaining_github ;;
  esac
}

count_completed_tasks() {
  case "$PRD_SOURCE" in
    markdown) count_completed_markdown ;;
    yaml) count_completed_yaml ;;
    github) count_completed_github ;;
  esac
}

mark_task_complete() {
  local task=$1
  local comment="${2:-}"
  case "$PRD_SOURCE" in
    markdown) mark_task_complete_markdown "$task" ;;
    yaml) mark_task_complete_yaml "$task" ;;
    github) mark_task_complete_github "$task" "$comment" ;;
  esac
}
