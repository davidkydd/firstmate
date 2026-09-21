#!/usr/bin/env bash
# fm-copilot-app.sh - capability check, package, explicit install, and exact
# uninstall for the GitHub Copilot app Firstmate extension.
#
# Usage:
#   fm-copilot-app.sh check [--copilot-command <path>]
#   fm-copilot-app.sh package --output <new-directory>
#   fm-copilot-app.sh install --fm-home <path> [--target <new-directory>] \
#     [--copilot-command <path>] --accept-experimental-canvas
#   fm-copilot-app.sh uninstall [--target <installed-directory>]
#   fm-copilot-app.sh verify-package <directory>
#
# `check` and `package` never install or enable anything. `install` is the only
# installation path and requires an explicit acknowledgement that the current
# Copilot canvas API is experimental. It creates a user-scoped extension under
# ~/.copilot/extensions/firstmate by default, requests no secret environment
# variables, writes no app database, and uses no private app API.
#
# `uninstall` removes only an installation whose exact file manifest still
# matches the generated receipt. It refuses modified or unrecognized content
# instead of deleting it. Neither command starts, stops, or restarts Firstmate
# supervision or the Copilot app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE="$SCRIPT_DIR/copilot-app-extension"
MIN_VERSION=1.0.84

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-copilot-app: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

private_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

canonical_existing_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" && pwd -P)
}

version_triplet() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr '.' ' '
}

version_supported() {
  local found=$1 got_major got_minor got_patch min_major min_minor min_patch
  read -r got_major got_minor got_patch <<EOF
$(version_triplet "$found")
EOF
  read -r min_major min_minor min_patch <<EOF
$(version_triplet "$MIN_VERSION")
EOF
  [ -n "${got_major:-}" ] || return 1
  if [ "$got_major" -ne "$min_major" ]; then [ "$got_major" -gt "$min_major" ]; return; fi
  if [ "$got_minor" -ne "$min_minor" ]; then [ "$got_minor" -gt "$min_minor" ]; return; fi
  [ "$got_patch" -ge "$min_patch" ]
}

validate_source() {
  local file
  command -v node >/dev/null 2>&1 || die "node is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  for file in extension.mjs bridge-client.mjs canvas-server.mjs package.json; do
    [ -f "$SOURCE/$file" ] && [ ! -L "$SOURCE/$file" ] || die "extension source is missing or unsafe: $SOURCE/$file"
  done
  node --check "$SOURCE/extension.mjs"
  node --check "$SOURCE/bridge-client.mjs"
  node --check "$SOURCE/canvas-server.mjs"
  jq -e '.name == "firstmate-copilot-app-extension" and (.version | type == "string")' \
    "$SOURCE/package.json" >/dev/null || die "extension package metadata is malformed"
}

check_capability() {
  local copilot_command=$1 output
  [ -x "$copilot_command" ] || command -v "$copilot_command" >/dev/null 2>&1 \
    || die "GitHub Copilot CLI not found: $copilot_command"
  output=$($copilot_command --version 2>&1) || die "GitHub Copilot CLI version check failed"
  version_supported "$output" \
    || die "Copilot $output is below the canvas proof floor $MIN_VERSION or has an unknown version format"
  validate_source
  printf 'compatible: %s\n' "$output"
  printf 'canvas: experimental; runtime capability is checked again by the extension\n'
}

copy_package_contents() { # <private-dir>
  local destination=$1 file
  for file in extension.mjs bridge-client.mjs canvas-server.mjs package.json; do
    cp "$SOURCE/$file" "$destination/$file"
    chmod 0600 "$destination/$file"
  done
}

copy_package() { # <new-dir>
  local destination=$1
  [ ! -e "$destination" ] || die "destination already exists: $destination"
  mkdir -p "$destination"
  chmod 0700 "$destination"
  copy_package_contents "$destination"
}

verify_package() { # <dir> [installed]
  local directory=$1 installed=${2:-0} file mode
  [ -d "$directory" ] && [ ! -L "$directory" ] || die "package is not a regular directory: $directory"
  mode=$(private_mode "$directory") || die "cannot inspect package permissions"
  [ "$mode" = 700 ] || die "package directory must have mode 0700: $directory (mode $mode)"
  for file in extension.mjs bridge-client.mjs canvas-server.mjs package.json; do
    [ -f "$directory/$file" ] && [ ! -L "$directory/$file" ] || die "package file is missing or unsafe: $directory/$file"
    mode=$(private_mode "$directory/$file") || die "cannot inspect package file permissions"
    [ "$mode" = 600 ] || die "package file must have mode 0600: $directory/$file (mode $mode)"
  done
  node --check "$directory/extension.mjs"
  node --check "$directory/bridge-client.mjs"
  node --check "$directory/canvas-server.mjs"
  jq -e '.name == "firstmate-copilot-app-extension"' "$directory/package.json" >/dev/null \
    || die "package metadata is malformed"
  if [ "$installed" = 1 ]; then
    [ -f "$directory/config.json" ] && [ ! -L "$directory/config.json" ] \
      || die "installed config is missing or unsafe"
    jq -e '
      keys == ["client_id","firstmate_root","fm_home","installed_copilot_version","protocol_version","schema"]
      and .schema == "firstmate.copilot-app-extension.v1"
      and .protocol_version == 1
      and .client_id == "copilot-app"
      and (.firstmate_root | type == "string")
      and (.fm_home | type == "string")
      and (.installed_copilot_version | type == "string")
    ' "$directory/config.json" >/dev/null || die "installed config is malformed"
  fi
}

write_receipt() { # <target>
  local target=$1 file
  {
    printf '{"schema":"firstmate.copilot-app-install.v1","files":{'
    first=1
    for file in extension.mjs bridge-client.mjs canvas-server.mjs package.json config.json; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '"%s":"sha256:%s"' "$file" "$(sha256_file "$target/$file")"
    done
    printf '}}\n'
  } > "$target/install-receipt.json"
  chmod 0600 "$target/install-receipt.json"
}

verify_receipt() { # <target>
  local target=$1 receipt="$1/install-receipt.json" file expected actual expected_list actual_list
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || die "install receipt is missing or unsafe: $receipt"
  jq -e '
    keys == ["files","schema"]
    and .schema == "firstmate.copilot-app-install.v1"
    and (.files | keys) == ["bridge-client.mjs","canvas-server.mjs","config.json","extension.mjs","package.json"]
    and all(.files[]; type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$receipt" >/dev/null || die "install receipt is malformed"
  for file in extension.mjs bridge-client.mjs canvas-server.mjs package.json config.json; do
    [ -f "$target/$file" ] && [ ! -L "$target/$file" ] || die "installed file is missing or unsafe: $target/$file"
    expected=$(jq -r --arg file "$file" '.files[$file]' "$receipt")
    actual="sha256:$(sha256_file "$target/$file")"
    [ "$actual" = "$expected" ] || die "installed file changed; refusing uninstall: $target/$file"
  done
  expected_list=$(printf '%s\n' bridge-client.mjs canvas-server.mjs config.json extension.mjs install-receipt.json package.json | LC_ALL=C sort)
  actual_list=$(find "$target" -mindepth 1 -maxdepth 1 -print | sed "s#^$target/##" | LC_ALL=C sort)
  [ "$actual_list" = "$expected_list" ] || die "installed directory contains unrecognized files; refusing uninstall: $target"
}

COMMAND=${1:-}
shift 2>/dev/null || true
case "$COMMAND" in
  check)
    copilot_command=copilot
    while [ "$#" -gt 0 ]; do
      case "$1" in --copilot-command) copilot_command=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
    done
    check_capability "$copilot_command"
    ;;
  package)
    output=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --output) output=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
    done
    [ -n "$output" ] || die "--output is required"
    validate_source
    copy_package "$output"
    verify_package "$output"
    printf 'packaged: %s\n' "$output"
    ;;
  verify-package)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    verify_package "$1"
    printf 'verified: %s\n' "$1"
    ;;
  install)
    fm_home='' target="${COPILOT_HOME:-$HOME/.copilot}/extensions/firstmate" copilot_command=copilot accepted=0 staging=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --fm-home) fm_home=${2:-}; shift 2 ;;
        --target) target=${2:-}; shift 2 ;;
        --copilot-command) copilot_command=${2:-}; shift 2 ;;
        --accept-experimental-canvas) accepted=1; shift ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [ "$accepted" = 1 ] || die "install requires --accept-experimental-canvas"
    fm_home=$(canonical_existing_dir "$fm_home") || die "--fm-home must name an existing non-symlink directory"
    [ -d "$fm_home/state" ] || die "Firstmate home has no state directory: $fm_home"
    check_output=$(check_capability "$copilot_command")
    copilot_version=$($copilot_command --version 2>&1 | tr '\n\r\t' '   ' | cut -c1-128)
    parent=${target%/*}
    [ "$parent" != "$target" ] || parent=.
    mkdir -p "$parent"
    parent=$(canonical_existing_dir "$parent") || die "install parent is unsafe: $parent"
    target="$parent/${target##*/}"
    [ ! -e "$target" ] || die "destination already exists: $target"
    staging=$(mktemp -d "$parent/.firstmate-install.XXXXXX") || die "cannot create installation staging directory"
    chmod 0700 "$staging"
    trap 'rm -rf -- "$staging"' EXIT
    copy_package_contents "$staging"
    jq -n --arg schema firstmate.copilot-app-extension.v1 --argjson protocol_version 1 \
      --arg firstmate_root "$ROOT" --arg fm_home "$fm_home" --arg client_id copilot-app \
      --arg installed_copilot_version "$copilot_version" \
      '{schema:$schema,protocol_version:$protocol_version,firstmate_root:$firstmate_root,fm_home:$fm_home,client_id:$client_id,installed_copilot_version:$installed_copilot_version}' \
      > "$staging/config.json"
    chmod 0600 "$staging/config.json"
    verify_package "$staging" 1
    write_receipt "$staging"
    mv -- "$staging" "$target"
    staging=''
    trap - EXIT
    printf '%s\n' "$check_output"
    printf 'installed: %s\n' "$target"
    printf 'Restart or reload GitHub Copilot to discover the extension.\n'
    ;;
  uninstall)
    target="${COPILOT_HOME:-$HOME/.copilot}/extensions/firstmate"
    while [ "$#" -gt 0 ]; do
      case "$1" in --target) target=${2:-}; shift 2 ;; *) usage >&2; exit 2 ;; esac
    done
    verify_package "$target" 1
    verify_receipt "$target"
    rm -rf -- "$target"
    printf 'uninstalled: %s\n' "$target"
    ;;
  *) usage >&2; exit 2 ;;
esac
