#!/usr/bin/env bash
set -euo pipefail

TARGET_APP="/Applications/ContextRing.app"
BUNDLE_ID="com.vladsboev.contextring"
AGENT_LABEL="com.vladsboev.contextring.autolaunch"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
PURGE_PREFS=false

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge-prefs] [-h|--help]

Options:
  --purge-prefs  Also delete saved preferences (UserDefaults)
  -h, --help     Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge-prefs)
      PURGE_PREFS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

detect_lang() {
  local locale_val="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  if [[ "$locale_val" == ru* ]]; then
    echo "ru"
    return
  fi
  if defaults read -g AppleLanguages 2>/dev/null | grep -qi '"ru'; then
    echo "ru"
    return
  fi
  echo "en"
}

LANG_CODE="$(detect_lang)"

msg() {
  local en="$1"
  local ru="$2"
  if [ "$LANG_CODE" = "ru" ]; then
    echo "$ru"
  else
    echo "$en"
  fi
}

is_running() {
  /usr/bin/lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null | /usr/bin/grep -q '^ASN:' || pgrep -x ContextRing >/dev/null 2>&1
}

if is_running; then
  msg "Stopping ContextRing..." "Останавливаю ContextRing..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! is_running; then
      break
    fi
    sleep 0.1
  done
  if is_running; then
    pkill -x ContextRing 2>/dev/null || true
  fi
fi

/bin/launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
if [ -f "$AGENT_PLIST" ]; then
  rm -f "$AGENT_PLIST"
  msg "Removed LaunchAgent: $AGENT_PLIST" "Удалён LaunchAgent: $AGENT_PLIST"
fi

USER_APP="$HOME/Applications/ContextRing.app"
REMOVED_ANY=false

admin_remove() {
  local dst="$1"
  local dst_escaped="${dst//\'/\'\\\'\'}"
  local cmd="rm -rf '${dst_escaped}'"

  if command -v osascript >/dev/null 2>&1; then
    if osascript -e 'on run argv' -e 'do shell script (item 1 of argv) with administrator privileges' -e 'end run' "$cmd" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if id -Gn 2>/dev/null | grep -qw admin; then
    sudo rm -rf "$dst"
    return $?
  fi

  return 1
}

for APP_PATH in "$TARGET_APP" "$USER_APP"; do
  if [ -d "$APP_PATH" ]; then
    APP_PARENT="$(dirname "$APP_PATH")"
    if [ -w "$APP_PARENT" ] && [ -w "$APP_PATH" ]; then
      rm -rf "$APP_PATH"
    else
      msg "Administrator privileges required to remove $APP_PATH..." "Для удаления $APP_PATH требуются права администратора..."
      admin_remove "$APP_PATH"
    fi
    msg "Removed app: $APP_PATH" "Удалено приложение: $APP_PATH"
    REMOVED_ANY=true
  fi
done

if [ "$REMOVED_ANY" = false ]; then
  msg "App not found at $TARGET_APP or $USER_APP" "Приложение не найдено в $TARGET_APP или $USER_APP"
fi

if [ "$PURGE_PREFS" = true ]; then
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  msg "Deleted saved preferences ($BUNDLE_ID)." "Удалены сохранённые настройки ($BUNDLE_ID)."
else
  msg "Preferences kept (pass --purge-prefs to delete them too)." \
      "Настройки сохранены (передай --purge-prefs, чтобы удалить и их)."
fi

msg "ContextRing uninstalled." "ContextRing полностью удалён."
