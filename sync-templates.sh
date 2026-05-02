#!/bin/bash
set -e

UPSTREAM_REPO="https://github.com/dani-garcia/vaultwarden.git"
TEMPLATES_DIR="templates"

fetch_latest_tag() {
  echo "Fetching latest tag..." >&2
  git ls-remote --tags --sort="v:refname" "$UPSTREAM_REPO" |
    grep -o 'refs/tags/.*' |
    grep -v '{}' |
    tail -n1 |
    sed 's#refs/tags/##'
}

send_telegram_notification() {
  local tag="$1"
  local message="Vaultwarden 模板已更新至 ${tag}
https://github.com/dani-garcia/vaultwarden/releases/tag/${tag}"

  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    -d "disable_web_page_preview=true" > /dev/null
}

main() {
  local latest_tag
  latest_tag=$(fetch_latest_tag)
  echo "Latest tag: $latest_tag"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  echo "Cloning repository..."
  git clone --depth 1 --branch "$latest_tag" "$UPSTREAM_REPO" "$tmp_dir"
  local new_templates_dir="$tmp_dir/src/static/templates"
  rm -rf "$new_templates_dir/scss"

  echo "Updating templates directory..."
  rm -rf "$TEMPLATES_DIR"
  cp -r "$new_templates_dir" "$TEMPLATES_DIR"
  rm -rf "$tmp_dir"

  echo "Committing changes..."
  git add .

  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "Update templates to $latest_tag"
    git push origin main
    send_telegram_notification "$latest_tag"
  fi

  echo "Done!"
}

main
