#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

ALLOWLIST=()

fail() {
  echo "::error::$1" >&2
  shift
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

if [[ ! -f .node-version ]]; then
  fail "Missing .node-version" \
    "The toolchain pin is the single source of truth for CI and local Node." \
    "Recreate it with the exact version the project builds on, e.g. 24.18.0."
fi

PIN="$(tr -d '[:space:]' < .node-version)"
if [[ ! "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail ".node-version must pin an exact x.y.z version (found: '$PIN')" \
    "A partial version (e.g. '24') lets setup-node float across the minor line," \
    "which is the drift this pin exists to prevent."
fi

FLOOR="$(node -p "require('./package.json').engines.node" 2>/dev/null || echo "")"
if [[ -n "$FLOOR" ]]; then
  if ! node -e '
    const [pin, range] = process.argv.slice(1);
    const m = range.match(/>=\s*(\d+)/);
    if (!m) process.exit(0);
    process.exit(Number(pin.split(".")[0]) >= Number(m[1]) ? 0 : 1);
  ' "$PIN" "$FLOOR"; then
    fail ".node-version ($PIN) is below the engines.node floor ($FLOOR)" \
      "pnpm runs with engine-strict=true, so an install on the pinned Node would fail."
  fi
fi

shopt -s nullglob
TARGETS=(.github/workflows/*.yml .github/workflows/*.yaml .github/composite-actions/*/action.yml)

violations=()
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  value="$(sed 's/^[0-9]*://' <<<"$rest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  allowed=0
  for entry in ${ALLOWLIST+"${ALLOWLIST[@]}"}; do
    [[ "$entry" == "$file:$value" ]] && allowed=1 && break
  done
  (( allowed )) || violations+=("$hit")
done < <(grep -rn '^[[:space:]]*node-version:' "${TARGETS[@]}" 2>/dev/null || true)

if (( ${#violations[@]} > 0 )); then
  fail "Hardcoded node-version in ${#violations[@]} step(s) — use the .node-version pin instead" \
    "" \
    "$(printf '  %s\n' "${violations[@]}")" \
    "Replace each with:" \
    "  node-version-file: .node-version" \
    "" \
    "A literal version floats setup-node across whatever release is newest on the day the job runs."
fi

setup_steps="$(grep -rc 'uses:[[:space:]]*actions/setup-node@' "${TARGETS[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
pinned_steps="$(grep -rc '^[[:space:]]*node-version-file:[[:space:]]*\.node-version[[:space:]]*$' "${TARGETS[@]}" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"

if [[ "$setup_steps" != "$pinned_steps" ]]; then
  fail "setup-node steps ($setup_steps) and '.node-version' pins ($pinned_steps) disagree" \
    "Every actions/setup-node step needs 'node-version-file: .node-version'." \
    "A step with no version key falls back to the runner's preinstalled Node."
fi

echo "Node version pins OK — $setup_steps setup-node step(s) read .node-version ($PIN)."
