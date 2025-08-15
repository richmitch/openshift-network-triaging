#!/usr/bin/env bash

set -euo pipefail

# Triage rx_cache_* ethtool stats on bonded interfaces across all OpenShift nodes.
# - Assumes you are already logged into the cluster with sufficient permissions.
# - Discovers bonds and their slave interfaces via /proc/net/bonding on each node.
# - Collects ethtool -S <iface> rx_cache_* counters for each bonded slave.
# - Flags potential issues when counters exceed threshold (default > 0).
# - Prints a human-readable table and a JSON document grouped by node→bond→interface→metric.

SCRIPT_NAME=$(basename "$0")

THRESHOLD=0
OUTPUT_MODE="both" # values: both|table|json
LABEL_SELECTOR=""
IMBALANCE_PERCENT=80   # percent share threshold for rx_cache_reuse
SKEW_RATIO=10          # ratio threshold for busy/full skew (max >= ratio * min)
BOND_FILTER=""        # comma-separated bond names to include (e.g., bond0 or bond0,bond1)

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--threshold N] [--label key=value[,k2=v2]] [--bond bond0[,bond1]] [--imbalance-threshold PCT] [--skew-ratio N] [--table-only|--json-only]

Options:
  -t, --threshold N   Numeric threshold to flag an issue (default: 0; issue if value > N)
  -l, --label SELECT  Label selector to filter nodes (e.g. role=worker or 'k1=v1,k2=v2')
  -b, --bond NAMES    Comma-separated list of bond device names to include (e.g. bond0 or bond0,bond1)
      --imbalance-threshold PCT  Percent share on a bond's top slave for rx_cache_reuse to flag imbalance (default: 80)
      --skew-ratio N             Ratio for rx_cache_busy/full skew across bond slaves to flag imbalance (default: 10)
      --table-only    Print only the table output
      --json-only     Print only the JSON output
  -h, --help          Show this help

Notes:
  - Requires 'oc' access with permission to run 'oc debug node/<node> ...'.
  - No changes are made on the nodes; only read-only commands are executed within chroot /host.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--threshold)
      shift
      if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
        echo "Error: --threshold requires a non-negative integer" >&2
        exit 1
      fi
      THRESHOLD=$1
      shift
      ;;
    --table-only)
      OUTPUT_MODE="table"
      shift
      ;;
    --json-only)
      OUTPUT_MODE="json"
      shift
      ;;
    --imbalance-threshold)
      shift
      if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
        echo "Error: --imbalance-threshold requires a non-negative integer percent" >&2
        exit 1
      fi
      IMBALANCE_PERCENT=$1
      shift
      ;;
    --skew-ratio)
      shift
      if [[ $# -eq 0 || ! "$1" =~ ^[0-9]+$ ]]; then
        echo "Error: --skew-ratio requires a positive integer" >&2
        exit 1
      fi
      SKEW_RATIO=$1
      shift
      ;;
    -b|--bond)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --bond requires a bond name or comma-separated list (e.g., bond0 or bond0,bond1)" >&2
        exit 1
      fi
      BOND_FILTER=$1
      shift
      ;;
    -l|--label)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Error: --label requires a selector value (e.g. role=worker)" >&2
        exit 1
      fi
      LABEL_SELECTOR=$1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

 # (deferred) bond imbalance computation occurs later after data collection

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found in PATH" >&2
    exit 1
  fi
}

require_cmd oc

get_all_nodes() {
  if [[ -n "$LABEL_SELECTOR" ]]; then
    oc get nodes -l "$LABEL_SELECTOR" -o name | sed 's#^node/##'
  else
    oc get nodes -o name | sed 's#^node/##'
  fi
}

# Run remote collection on a node. Prints only lines of the form:
#   bond=<bond> iface=<iface> metric=<metric> value=<value>
collect_on_node() {
  local node="$1"
  oc debug "node/${node}" --quiet -- chroot /host env BOND_SELECT="${BOND_FILTER}" bash -lc '
    set -euo pipefail
    # Normalize optional comma-separated bond selector (strip spaces)
    BOND_SELECT_CLEAN="${BOND_SELECT:-}"
    BOND_SELECT_CLEAN="${BOND_SELECT_CLEAN//[[:space:]]/}"
    [ -d /proc/net/bonding ] || exit 0
    for bf in /proc/net/bonding/*; do
      [ -e "$bf" ] || continue
      bond_name=$(basename "$bf")
      # Apply bond filter if provided (BOND_SELECT is a comma-separated list)
      if [ -n "${BOND_SELECT_CLEAN}" ]; then
        case ",${BOND_SELECT_CLEAN}," in
          *",${bond_name},"*) ;;
          *) continue ;;
        esac
      fi
      # Extract slave interface names
      awk -F": " "/^Slave Interface:/ {print \$2}" "$bf" | while read -r iface; do
        # ethtool may not expose rx_cache_* for all drivers; ignore errors
        ethtool -S "$iface" 2>/dev/null | awk -v bond="$bond_name" -v iface="$iface" -F": " '\''/^[[:space:]]*rx_cache_/ {gsub(/^[[:space:]]+/, "", $1); printf "bond=%s iface=%s metric=%s value=%s\n", bond, iface, $1, $2}'\''
      done
    done
  ' 2>/dev/null | awk -v n="$node" '/^bond=/{print "node=" n " " $0}'
}

declare -a RAW_RESULTS
RAW_RESULTS=()
declare -a NODES

# Collect nodes (portable for bash 3.2)
NODES=()
while IFS= read -r _n; do
  [[ -n "$_n" ]] && NODES+=("$_n")
done < <(get_all_nodes)

if [[ ${#NODES[@]} -eq 0 ]]; then
  if [[ -n "$LABEL_SELECTOR" ]]; then
    echo "No nodes found for label selector: '$LABEL_SELECTOR'. Are you logged into the cluster?" >&2
  else
    echo "No nodes found. Are you logged into the cluster?" >&2
  fi
  exit 1
fi

for node in "${NODES[@]}"; do
  while IFS= read -r line; do
    RAW_RESULTS+=("$line")
  done < <(collect_on_node "$node")
done

if [[ ${#RAW_RESULTS[@]} -eq 0 ]]; then
  echo "No bonded interfaces with rx_cache_* statistics found on any node." >&2
  # Still print an empty JSON if requested
  if [[ "$OUTPUT_MODE" == "json" || "$OUTPUT_MODE" == "both" ]]; then
    echo '{"nodes":[]}'
  fi
  exit 0
fi

# Sort results to ensure stable grouped output (portable for bash 3.2)
declare -a SORTED_RESULTS
SORTED_RESULTS=()
while IFS= read -r _line; do
  SORTED_RESULTS+=("$_line")
done < <(printf '%s\n' "${RAW_RESULTS[@]}" | sort -k1,1 -k2,2 -k3,3 -k4,4)

# Build structures
declare -A SET_NODES=()
declare -A SET_BONDS=()        # key: node|bond
declare -A SET_IFACES=()       # key: node|bond|iface
declare -A METRIC_VALUE=()     # key: node|bond|iface|metric -> value
declare -A IFACE_HAS_ISSUE=()  # key: node|bond|iface -> 1

# Bond-level imbalance tracking
declare -A BOND_IMBALANCED=()         # key: node|bond -> 1
declare -A BOND_IMBALANCE_REASONS=()  # key: node|bond -> string (semicolon-separated)
declare -A BOND_TOP_REUSE_IFACE=()    # key: node|bond -> iface name
declare -A BOND_TOP_REUSE_SHARE=()    # key: node|bond -> integer percent
declare -A BOND_BUSY_SKEW_RATIO=()    # key: node|bond -> integer ratio (max/min)
declare -A BOND_FULL_SKEW_RATIO=()    # key: node|bond -> integer ratio (max/min)

parse_line_tokens() {
  local line="$1"
  local _node="" _bond="" _iface="" _metric="" _value=""
  local token key val
  for token in $line; do
    key=${token%%=*}
    val=${token#*=}
    case "$key" in
      node) _node="$val" ;;
      bond) _bond="$val" ;;
      iface) _iface="$val" ;;
      metric) _metric="$val" ;;
      value) _value="$val" ;;
    esac
  done
  printf '%s\t%s\t%s\t%s\t%s\n' "$_node" "$_bond" "$_iface" "$_metric" "$_value"
}

for line in "${SORTED_RESULTS[@]}"; do
  IFS=$'\t' read -r node bond iface metric value < <(parse_line_tokens "$line")
  [[ -n "$node" && -n "$bond" && -n "$iface" && -n "$metric" && -n "$value" ]] || continue
  SET_NODES["$node"]=1
  SET_BONDS["$node|$bond"]=1
  SET_IFACES["$node|$bond|$iface"]=1
  METRIC_VALUE["$node|$bond|$iface|$metric"]=$value
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value > THRESHOLD )); then
    IFACE_HAS_ISSUE["$node|$bond|$iface"]=1
  fi
done

print_table() {
  # Build a TSV of header + rows and let awk compute widths and render table.
  {
    printf 'NODE\tBOND\tINTERFACE\tMETRIC\tVALUE\n'
    local node bond iface metric value
    for line in "${SORTED_RESULTS[@]}"; do
      IFS=$'\t' read -r node bond iface metric value < <(parse_line_tokens "$line")
      [[ -n "$node" ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$node" "$bond" "$iface" "$metric" "$value"
    done
  } | awk -F'\t' '
    function dashes(n,  s,i){ s=""; for(i=0;i<n;i++) s=s"-"; return s }
    {
      rows[NR,1]=$1; rows[NR,2]=$2; rows[NR,3]=$3; rows[NR,4]=$4; rows[NR,5]=$5;
      for(i=1;i<=5;i++){ l=length($i); if (l>width[i]) width[i]=l }
      maxNR=NR
    }
    END{
      # Format strings: left-align cols 1-4, right-align col 5
      fmt=sprintf("%%-%ds %%-%ds %%-%ds %%-%ds %%%ds\n", width[1],width[2],width[3],width[4],width[5])
      # Header
      printf fmt, rows[1,1], rows[1,2], rows[1,3], rows[1,4], rows[1,5]
      # Separator
      printf fmt, dashes(width[1]), dashes(width[2]), dashes(width[3]), dashes(width[4]), dashes(width[5])
      # Data rows
      for(n=2;n<=maxNR;n++){
        printf fmt, rows[n,1], rows[n,2], rows[n,3], rows[n,4], rows[n,5]
      }
    }'

  # Imbalance summary
  if [[ -n "${!BOND_IMBALANCED[@]}" ]]; then
    echo
    echo "Imbalance summary (reuse_share >= ${IMBALANCE_PERCENT}% or skew >= ${SKEW_RATIO}x):"
    # Sort by node|bond key for stable output
    printf '%s\n' "${!BOND_IMBALANCED[@]}" | sort | while IFS= read -r kb; do
      node=${kb%%|*}; bond=${kb#*|}
      reasons=${BOND_IMBALANCE_REASONS[$kb]}
      echo "- ${node} ${bond}: ${reasons}"
    done
  fi
}

print_json() {
  local first_node=1 first_bond first_iface first_metric
  printf '{"nodes":['
  # nodes sorted
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ $first_node -eq 0 ]]; then printf ','; fi
    first_node=0
    printf '{"name":"%s","bonds":[' "$node"
    first_bond=1
    # bonds for node
    while IFS= read -r bond_key; do
      local bond=${bond_key#*|}
      if [[ $first_bond -eq 0 ]]; then printf ','; fi
      first_bond=0
      # Bond-level imbalance fields
      local kb="$node|$bond"
      local imb=$([[ -n "${BOND_IMBALANCED[$kb]:-}" ]] && echo true || echo false)
      local reasons=${BOND_IMBALANCE_REASONS[$kb]:-}
      local topIface=${BOND_TOP_REUSE_IFACE[$kb]:-}
      local topShare=${BOND_TOP_REUSE_SHARE[$kb]:-0}
      local busySkew=${BOND_BUSY_SKEW_RATIO[$kb]:-0}
      local fullSkew=${BOND_FULL_SKEW_RATIO[$kb]:-0}
      printf '{"name":"%s","imbalance":%s,"imbalanceReasons":[' "$bond" "$imb"
      if [[ -n "$reasons" ]]; then
        # reasons is a semicolon-separated string; print as single JSON string to avoid complex splitting
        printf '"%s"' "$reasons"
      fi
      printf '],"topReuse":{"interface":"%s","sharePercent":%s},"busySkewRatio":%s,"fullSkewRatio":%s,"interfaces":[' \
        "$topIface" "$topShare" "$busySkew" "$fullSkew"
      first_iface=1
      # interfaces for node|bond
      while IFS= read -r iface_key; do
        local iface=${iface_key##*|}
        if [[ $first_iface -eq 0 ]]; then printf ','; fi
        first_iface=0
        # rx_cache metrics
        local iface_issue=0
        printf '{"name":"%s","rx_cache":{' "$iface"
        first_metric=1
        # metrics for node|bond|iface
        while IFS= read -r metric_key; do
          local metric=${metric_key##*|}
          local value=${METRIC_VALUE["$node|${bond}|${iface}|${metric}"]}
          [[ "$value" =~ ^[0-9]+$ ]] || value=0
          if (( value > THRESHOLD )); then iface_issue=1; fi
          if [[ $first_metric -eq 0 ]]; then printf ','; fi
          first_metric=0
          printf '"%s":%s' "$metric" "$value"
        done < <(printf '%s\n' "${!METRIC_VALUE[@]}" | awk -v n="$node" -v b="$bond" -v i="$iface" -F'\|' '$1==n && $2==b && $3==i {print $0}' | sort)
        printf '},"issue":%s}' "$([[ $iface_issue -eq 1 ]] && echo true || echo false)"
      done < <(printf '%s\n' "${!SET_IFACES[@]}" | awk -v n="$node" -v b="$bond" -F'\|' '$1==n && $2==b {print $0}' | sort)
      printf ']}'
    done < <(printf '%s\n' "${!SET_BONDS[@]}" | awk -v n="$node" -F'\|' '$1==n {print $0}' | sort)
    printf ']}'
  done < <(printf '%s\n' "${!SET_NODES[@]}" | sort)
  printf ']}'
  printf '\n'
}

# Compute bond-level imbalance after metrics are collected
compute_bond_imbalance() {
  local node bond iface kb kbi reuse total_reuse max_reuse max_iface
  local busy max_busy min_busy full max_full min_full
  for kb in "${!SET_BONDS[@]}"; do
    node=${kb%%|*}; bond=${kb#*|}
    total_reuse=0
    max_reuse=0
    max_iface=""
    max_busy=0; min_busy=0
    max_full=0; min_full=0
    # Iterate interfaces for this bond
    while IFS= read -r kbi; do
      iface=${kbi##*|}
      # reuse
      reuse=${METRIC_VALUE["$node|$bond|$iface|rx_cache_reuse"]:-0}
      [[ "$reuse" =~ ^[0-9]+$ ]] || reuse=0
      (( total_reuse += reuse ))
      if (( reuse > max_reuse )); then max_reuse=$reuse; max_iface=$iface; fi
      # busy
      busy=${METRIC_VALUE["$node|$bond|$iface|rx_cache_busy"]:-0}
      [[ "$busy" =~ ^[0-9]+$ ]] || busy=0
      if (( busy > max_busy )); then max_busy=$busy; fi
      if (( busy > 0 )); then
        if (( min_busy == 0 || busy < min_busy )); then min_busy=$busy; fi
      fi
      # full
      full=${METRIC_VALUE["$node|$bond|$iface|rx_cache_full"]:-0}
      [[ "$full" =~ ^[0-9]+$ ]] || full=0
      if (( full > max_full )); then max_full=$full; fi
      if (( full > 0 )); then
        if (( min_full == 0 || full < min_full )); then min_full=$full; fi
      fi
    done < <(printf '%s\n' "${!SET_IFACES[@]}" | awk -v n="$node" -v b="$bond" -F'\|' '$1==n && $2==b {print $0}' | sort)

    local reasons=()
    # reuse share
    local share=0
    if (( total_reuse > 0 )); then
      share=$(( max_reuse * 100 / total_reuse ))
      BOND_TOP_REUSE_SHARE["$kb"]=$share
      BOND_TOP_REUSE_IFACE["$kb"]=$max_iface
      if (( share >= IMBALANCE_PERCENT )); then
        reasons+=("top rx_cache_reuse share ${share}% on ${max_iface}")
      fi
    else
      BOND_TOP_REUSE_SHARE["$kb"]=0
      BOND_TOP_REUSE_IFACE["$kb"]=""
    fi

    # busy skew
    local busy_skew=0
    if (( min_busy == 0 && max_busy > 0 )); then
      busy_skew=999999
    elif (( min_busy > 0 )); then
      busy_skew=$(( max_busy / min_busy ))
    fi
    BOND_BUSY_SKEW_RATIO["$kb"]=$busy_skew
    if (( busy_skew >= SKEW_RATIO )); then
      reasons+=("rx_cache_busy skew ${busy_skew}x")
    fi

    # full skew
    local full_skew=0
    if (( min_full == 0 && max_full > 0 )); then
      full_skew=999999
    elif (( min_full > 0 )); then
      full_skew=$(( max_full / min_full ))
    fi
    BOND_FULL_SKEW_RATIO["$kb"]=$full_skew
    if (( full_skew >= SKEW_RATIO )); then
      reasons+=("rx_cache_full skew ${full_skew}x")
    fi

    if (( ${#reasons[@]} > 0 )); then
      BOND_IMBALANCED["$kb"]=1
      # Join reasons with semicolons
      local joined="${reasons[0]}"; local i
      for ((i=1;i<${#reasons[@]};i++)); do joined+="; ${reasons[$i]}"; done
      BOND_IMBALANCE_REASONS["$kb"]=$joined
    fi
  done
}

# Compute bond-level imbalance now that metrics and sets are populated
compute_bond_imbalance

case "$OUTPUT_MODE" in
  table)
    print_table
    ;;
  json)
    print_json
    ;;
  both)
    print_table
    echo
    print_json
    ;;
esac


