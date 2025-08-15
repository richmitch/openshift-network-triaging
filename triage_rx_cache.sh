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

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--threshold N] [--table-only|--json-only]

Options:
  -t, --threshold N   Numeric threshold to flag an issue (default: 0; issue if value > N)
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found in PATH" >&2
    exit 1
  fi
}

require_cmd oc

get_all_nodes() {
  oc get nodes -o name | sed 's#^node/##'
}

# Run remote collection on a node. Prints only lines of the form:
#   bond=<bond> iface=<iface> metric=<metric> value=<value>
collect_on_node() {
  local node="$1"
  oc debug "node/${node}" --quiet -- chroot /host bash -lc '
    set -euo pipefail
    [ -d /proc/net/bonding ] || exit 0
    for bf in /proc/net/bonding/*; do
      [ -e "$bf" ] || continue
      bond_name=$(basename "$bf")
      # Extract slave interface names
      awk -F": " "/^Slave Interface:/ {print \$2}" "$bf" | while read -r iface; do
        # ethtool may not expose rx_cache_* for all drivers; ignore errors
        ethtool -S "$iface" 2>/dev/null | awk -v bond="$bond_name" -v iface="$iface" -F": " '\''/^[[:space:]]*rx_cache_/ {gsub(/^[[:space:]]+/, "", $1); printf "bond=%s iface=%s metric=%s value=%s\n", bond, iface, $1, $2}'\''
      done
    done
  ' 2>/dev/null | awk -v n="$node" '/^bond=/{print "node=" n " " $0}'
}

declare -a RAW_RESULTS

readarray -t NODES < <(get_all_nodes)

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "No nodes found. Are you logged into the cluster?" >&2
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

# Sort results to ensure stable grouped output
readarray -t SORTED_RESULTS < <(printf '%s\n' "${RAW_RESULTS[@]}" | sort -k1,1 -k2,2 -k3,3 -k4,4)

# Build structures
declare -A SET_NODES=()
declare -A SET_BONDS=()        # key: node|bond
declare -A SET_IFACES=()       # key: node|bond|iface
declare -A METRIC_VALUE=()     # key: node|bond|iface|metric -> value
declare -A IFACE_HAS_ISSUE=()  # key: node|bond|iface -> 1

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
  printf '%-30s %-16s %-16s %-28s %12s %-7s\n' "NODE" "BOND" "INTERFACE" "METRIC" "VALUE" "ISSUE"
  printf '%-30s %-16s %-16s %-28s %12s %-7s\n' "------------------------------" "----------------" "----------------" "----------------------------" "------------" "-------"
  local node bond iface metric value issue
  for line in "${SORTED_RESULTS[@]}"; do
    IFS=$'\t' read -r node bond iface metric value < <(parse_line_tokens "$line")
    [[ -n "$node" ]] || continue
    issue="no"
    if [[ -n "${IFACE_HAS_ISSUE["$node|$bond|$iface"]:-}" ]]; then
      issue="yes"
    fi
    printf '%-30s %-16s %-16s %-28s %12s %-7s\n' "$node" "$bond" "$iface" "$metric" "$value" "$issue"
  done
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
      printf '{"name":"%s","interfaces":[' "$bond"
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


