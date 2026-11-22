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

if [ -d "$TARGET_APP" ]; then
  if [ -w "/Applications" ] && [ -w "$TARGET_APP" ]; then
    rm -rf "$TARGET_APP"
  else
    sudo rm -rf "$TARGET_APP"
  fi
  msg "Removed app: $TARGET_APP" "Удалено приложение: $TARGET_APP"
else
  msg "App not found at $TARGET_APP" "Приложение не найдено в $TARGET_APP"
fi

if [ "$PURGE_PREFS" = true ]; then
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  msg "Deleted saved preferences ($BUNDLE_ID)." "Удалены сохранённые настройки ($BUNDLE_ID)."
else
  msg "Preferences kept (pass --purge-prefs to delete them too)." \
      "Настройки сохранены (передай --purge-prefs, чтобы удалить и их)."
fi

msg "ContextRing uninstalled." "ContextRing полностью удалён."
