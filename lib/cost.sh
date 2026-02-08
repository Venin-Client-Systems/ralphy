# ============================================
# COST CALCULATION
# ============================================

calculate_cost() {
  local input=$1
  local output=$2

  if command -v bc &>/dev/null; then
    echo "scale=4; ($input * 0.000003) + ($output * 0.000015)" | bc
  else
    echo "N/A"
  fi
}
