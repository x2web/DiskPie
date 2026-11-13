#!/bin/bash
# Tags v<version>, pushes the tag and creates a GitHub release with the given assets.
# The token comes from the macOS keychain and only lives in a variable of this script:
#   DISKPIE_GITHUB_KEYCHAIN_SERVICE (default tn-workspace-github-pat)
#   DISKPIE_GITHUB_KEYCHAIN_ACCOUNT (default x2web)
# Usage: scripts/publish-release.sh <version> <asset>...
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/publish-release.sh <version> <asset>...}"
shift
REPO="${DISKPIE_GITHUB_REPO:-x2web/DiskPie}"
SERVICE="${DISKPIE_GITHUB_KEYCHAIN_SERVICE:-tn-workspace-github-pat}"
ACCOUNT="${DISKPIE_GITHUB_KEYCHAIN_ACCOUNT:-x2web}"
TAG="v$VERSION"

T="$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w)"
mask() { sed "s/$T/***/g"; }
api() { curl -sS -H "Authorization: Bearer $T" -H "Accept: application/vnd.github+json" "$@"; }

NOTES="$(awk -v v="## $VERSION" '$0 == v { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md)"
[[ -n "$NOTES" ]] || { echo "error: no '## $VERSION' section in CHANGELOG.md" >&2; exit 1; }

git tag -a "$TAG" -m "DiskPie $VERSION"
git -c credential.helper= push "https://$ACCOUNT:$T@github.com/$REPO.git" "$TAG" 2>&1 | mask

BODY="$(TAG="$TAG" VERSION="$VERSION" NOTES="$NOTES" python3 -c 'import json, os; print(json.dumps({"tag_name": os.environ["TAG"], "name": "DiskPie " + os.environ["VERSION"], "body": os.environ["NOTES"]}))')"
RELEASE="$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY")"
RELEASE_ID="$(printf '%s' "$RELEASE" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
[[ -n "$RELEASE_ID" ]] || { printf '%s\n' "$RELEASE" | mask >&2; exit 1; }

for asset in "$@"; do
    name="$(basename "$asset")"
    api -X POST -H "Content-Type: application/octet-stream" --data-binary "@$asset" \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$name" \
        | python3 -c 'import json, sys; d = json.load(sys.stdin); print("uploaded", d.get("name"), d.get("state"))' | mask
done
echo "https://github.com/$REPO/releases/tag/$TAG"
