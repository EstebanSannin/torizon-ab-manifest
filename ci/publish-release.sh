#!/usr/bin/env bash
# Create-or-update a GitHub Release (tag from metadata.env) and upload every
# artifact in $ART_DIR. Pure curl + jq — no third-party actions.
#
# Env:
#   GH_TOKEN           token with contents:write (the workflow's GITHUB_TOKEN)
#   REPO               owner/repo (github.repository)
#   ART_DIR            dir holding the artifacts + metadata.env + SHA256SUMS
#   TARGET_COMMITISH   (optional) commit the tag points at (github.sha)
set -euo pipefail
: "${GH_TOKEN:?}" "${REPO:?}" "${ART_DIR:?}"

# shellcheck disable=SC1091
. "$ART_DIR/metadata.env"
: "${TAG:?}" "${BUILD_ID:?}"

API="https://api.github.com"
UPLOADS="https://uploads.github.com"
hdr=(-H "Authorization: Bearer $GH_TOKEN"
     -H "Accept: application/vnd.github+json"
     -H "X-GitHub-Api-Version: 2022-11-28")

body="$(printf 'Automated build (torizon-ab pipeline).\n\n- machine: `%s`\n- backend: `%s`\n- channel: `%s`\n- os version: `%s`\n\n### SHA256SUMS\n```\n%s\n```\n' \
  "$MACHINE" "$BACKEND" "$CHANNEL" "$OS_VERSION" "$(cat "$ART_DIR/SHA256SUMS")")"

# 1) find-or-create the release for this tag.
#    NB: no `-f` on the lookup — a 404 (tag not yet released) is expected and must
#    NOT abort under `pipefail`; we detect "missing" by the absence of an id.
rid="$(curl -sS "${hdr[@]}" "$API/repos/$REPO/releases/tags/$TAG" | jq -r '.id // empty')"
if [ -z "$rid" ]; then
  payload="$(jq -n --arg t "$TAG" --arg n "$BUILD_ID" --arg b "$body" --arg c "${TARGET_COMMITISH:-}" \
    '{tag_name:$t, name:$n, body:$b} + (if $c=="" then {} else {target_commitish:$c} end)')"
  resp="$(curl -sS "${hdr[@]}" -X POST "$API/repos/$REPO/releases" -d "$payload")"
  rid="$(printf '%s' "$resp" | jq -r '.id // empty')"
  if [ -z "$rid" ]; then
    echo "release create failed:" >&2
    printf '%s\n' "$resp" | jq -r '.message // .' >&2
    exit 1
  fi
  echo "created release $TAG (id=$rid)"
else
  # refresh the notes on an existing tag (idempotent re-runs)
  curl -fsS "${hdr[@]}" -X PATCH "$API/repos/$REPO/releases/$rid" \
    -d "$(jq -n --arg n "$BUILD_ID" --arg b "$body" '{name:$n, body:$b}')" >/dev/null
  echo "updating release $TAG (id=$rid)"
fi

# 2) upload each artifact, replacing any same-named asset (idempotent)
existing="$(curl -fsS "${hdr[@]}" "$API/repos/$REPO/releases/$rid/assets")"
for f in "$ART_DIR"/*; do
  name="$(basename "$f")"
  aid="$(printf '%s' "$existing" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id')"
  if [ -n "$aid" ]; then
    curl -fsS "${hdr[@]}" -X DELETE "$API/repos/$REPO/releases/assets/$aid" >/dev/null
    echo "  replaced $name"
  fi
  curl -fsS "${hdr[@]}" -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" "$UPLOADS/repos/$REPO/releases/$rid/assets?name=$name" >/dev/null
  echo "  uploaded $name"
done

echo "release: https://github.com/$REPO/releases/tag/$TAG"
