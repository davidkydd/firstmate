# shellcheck shell=bash disable=SC2034
# Remote second-mate transport-profile primitives.
# Usage: . bin/fm-remote-transport-lib.sh
#
# config/remote-transports is optional and primary-local.  Its exact format is:
#
#   schema=fm-remote-transports.v1
#   route <ssh-alias> devbox-wsl subscription=<azure-subscription-uuid>
#
# Blank lines and lines beginning with # are ignored after the schema line.
# The profile does not contain an endpoint, command, credential, or SSH option:
# the named OpenSSH alias remains the route and owns HostName, Port, User,
# IdentityFile, and HostKeyAlias.  A devbox-wsl record only selects the fixed
# transport hardening in fm-on.sh and the matching remote-doctor diagnostics.
# An absent file leaves every route on the existing generic SSH behavior.

FM_REMOTE_TRANSPORT_CONFIG_FILE=remote-transports
FM_REMOTE_TRANSPORT_SCHEMA=fm-remote-transports.v1
FM_REMOTE_TRANSPORT_PROFILE=ssh
FM_REMOTE_TRANSPORT_SUBSCRIPTION=
FM_REMOTE_TRANSPORT_ERROR=
FM_REMOTE_TRANSPORT_DEVBOX_CONNECT_TIMEOUT=10
FM_REMOTE_TRANSPORT_DEVBOX_CONNECTION_ATTEMPTS=2

fm_remote_transport_fail() {
  FM_REMOTE_TRANSPORT_ERROR=$1
  return 1
}

fm_remote_transport_link_count() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_remote_transport_config_load() { # <config-dir> <ssh-alias>
  local config_dir=$1 wanted_alias=$2 path links bytes line line_no=0 schema_seen=0
  local alias profile subscription extra route_count=0 seen=' '
  FM_REMOTE_TRANSPORT_PROFILE=ssh
  FM_REMOTE_TRANSPORT_SUBSCRIPTION=
  FM_REMOTE_TRANSPORT_ERROR=

  case "$wanted_alias" in
    ''|-*|*[!A-Za-z0-9._-]*)
      fm_remote_transport_fail "unsafe SSH alias: $wanted_alias"
      return 1
      ;;
  esac

  path="$config_dir/$FM_REMOTE_TRANSPORT_CONFIG_FILE"
  if [ -L "$config_dir" ]; then
    fm_remote_transport_fail "config directory is symlinked: $config_dir"
    return 1
  fi
  if [ -e "$config_dir" ] && [ ! -d "$config_dir" ]; then
    fm_remote_transport_fail "config directory is not a directory: $config_dir"
    return 1
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ ! -d "$config_dir" ]; then
    fm_remote_transport_fail "config directory is not a directory: $config_dir"
    return 1
  fi
  if [ -L "$path" ]; then
    fm_remote_transport_fail "$path is symlinked"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_remote_transport_fail "$path is not a regular file"
    return 1
  fi
  links=$(fm_remote_transport_link_count "$path") || {
    fm_remote_transport_fail "could not inspect $path link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_remote_transport_fail "$path is hardlinked"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ') || {
    fm_remote_transport_fail "could not measure $path"
    return 1
  }
  case "$bytes" in ''|*[!0-9]*)
    fm_remote_transport_fail "could not measure $path"
    return 1
    ;;
  esac
  if [ "$bytes" -gt 65536 ]; then
    fm_remote_transport_fail "$path exceeds the 65536-byte bound"
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$schema_seen" -eq 0 ]; then
      [ "$line" = "schema=$FM_REMOTE_TRANSPORT_SCHEMA" ] || {
        fm_remote_transport_fail "$path line 1 must be schema=$FM_REMOTE_TRANSPORT_SCHEMA"
        return 1
      }
      schema_seen=1
      continue
    fi
    case "$line" in ''|'#'*) continue ;; esac
    alias=
    profile=
    subscription=
    extra=
    read -r alias profile subscription extra <<EOF
${line#route }
EOF
    case "$line" in route\ *) ;; *)
      fm_remote_transport_fail "$path line $line_no is not a route record"
      return 1
      ;;
    esac
    case "$alias" in ''|-*|*[!A-Za-z0-9._-]*)
      fm_remote_transport_fail "$path line $line_no has an unsafe SSH alias"
      return 1
      ;;
    esac
    [ "${#alias}" -le 255 ] || {
      fm_remote_transport_fail "$path line $line_no has an SSH alias longer than 255 bytes"
      return 1
    }
    [ "$profile" = devbox-wsl ] && [ -z "$extra" ] || {
      fm_remote_transport_fail "$path line $line_no must be 'route <ssh-alias> devbox-wsl subscription=<azure-subscription-uuid>'"
      return 1
    }
    case "$subscription" in
      subscription=[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
      *)
        fm_remote_transport_fail "$path line $line_no has an invalid Azure subscription UUID"
        return 1
        ;;
    esac
    subscription=${subscription#subscription=}
    subscription=$(printf '%s' "$subscription" | tr 'A-F' 'a-f')
    case "$seen" in *" $alias "*)
      fm_remote_transport_fail "$path repeats SSH alias $alias"
      return 1
      ;;
    esac
    seen="$seen$alias "
    route_count=$((route_count + 1))
    [ "$route_count" -le 128 ] || {
      fm_remote_transport_fail "$path contains more than 128 routes"
      return 1
    }
    if [ "$alias" = "$wanted_alias" ]; then
      FM_REMOTE_TRANSPORT_PROFILE=$profile
      FM_REMOTE_TRANSPORT_SUBSCRIPTION=$subscription
    fi
  done < "$path"

  [ "$schema_seen" -eq 1 ] || {
    fm_remote_transport_fail "$path is empty"
    return 1
  }
  return 0
}
