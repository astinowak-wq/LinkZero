#!/usr/bin/env bash
set -euo pipefail

# download-latest-branch.sh
# Usage: ./download-latest-branch.sh [owner] [repo]
# Defaults: owner=astinowak-wq repo=LinkZero

OWNER=""${1:-astinowak-wq}""
REPO=""${2:-LinkZero}""
API="https://api.github.com/repos/$OWNER/$REPO"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

# Use token if provided to avoid strict rate limits
AUTH_HEADER=""
if [[ -n ""${GITHUB_TOKEN:-}"" ]]; then
  AUTH_HEADER="-H Authorization: token "+
fi

TMPDIR=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Fetching branches for $OWNER/$REPO..."
branches_json=$(eval curl -s $AUTH_HEADER "$API/branches?per_page=100")

branches=$(python3 - <<'PY'
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for b in data:
    print(b.get('name'))
PY
<<<"$branches_json")

if [[ -z "$branches" ]]; then
  echo "No branches found or API error." >&2
  exit 1
fi

latest_branch=""
latest_date="1970-01-01T00:00:00Z"

for b in $branches; do
  commit_json=$(eval curl -s $AUTH_HEADER "$API/commits/$b")
  date=$(python3 - <<'PY'
import sys, json
try:
    c = json.load(sys.stdin)
    print(c.get('commit', {}).get('committer', {}).get('date', ''))
except Exception:
    print('')
PY
<<<"$commit_json")
  if [[ -n "$date" ]]; then
    # ISO8601 lexical compare works for timestamps in same format
    if [[ "$date" > "$latest_date" ]]; then
      latest_date="$date"
      latest_branch="$b"
    fi
  fi
done

if [[ -z "$latest_branch" ]]; then
  echo "Unable to determine latest branch." >&2
  exit 1
fi

echo "Latest branch determined: $latest_branch (commit date: $latest_date)"

ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$latest_branch.tar.gz"
OUT="$PWD/${REPO}-${latest_branch}.tar.gz"

echo "Downloading $ARCHIVE_URL -> $OUT"
curl -L -o "$OUT" "$ARCHIVE_URL"

echo "Extracting archive..."
tar -xzf "$OUT"

echo "Extracted to:"
ls -d "${REPO}-${latest_branch}"* || true

echo "Done. You can inspect the extracted directory or run: cd ${REPO}-${latest_branch}"