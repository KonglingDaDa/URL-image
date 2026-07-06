#!/usr/bin/env bash
# Guard against Bash 4+ syntax in shell scripts (macOS /bin/bash is 3.2).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd "$script_dir/.." && pwd)"
scripts_dir="${skill_root}/scripts"

failures=0

check_pattern() {
  local label="$1"
  local pattern="$2"
  local matches
  matches="$(
    grep -R -n -E "$pattern" "$scripts_dir" --include='*.sh' \
      | grep -v -E '^[^:]*:[0-9]+:[[:space:]]*#' \
      || true
  )"
  if [[ -n "$matches" ]]; then
    failures=$((failures + 1))
    printf 'FAIL %s\n' "$label" >&2
    printf '%s\n' "$matches" >&2
  else
    printf 'OK   %s\n' "$label"
  fi
}

check_pattern 'no local -n namerefs' '[[:space:]]local -n '
check_pattern 'no mapfile/readarray' '[[:space:]]mapfile|[[:space:]]readarray'
check_pattern 'no ${var,,} lowercase expansion' '\$\{[^}]+\,\,\}'

if ((failures > 0)); then
  printf '\n%d bash compatibility checks failed.\n' "$failures" >&2
  exit 1
fi

printf '\nAll bash compatibility checks passed.\n'