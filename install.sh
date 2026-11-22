#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_APP="$ROOT_DIR/build/ContextRing.app"
TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/ContextRing.app"
BUNDLE_ID="com.vladsboev.contextring"

UNIVERSAL=false
SKIP_BUILD=false
NO_LAUNCH=false
USER_INSTALL=false

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --universal   Build a Universal Binary (x86_64 + arm64) before installing
  --skip-build  Install existing build/ContextRing.app without rebuilding
  --no-launch   Install without opening ContextRing.app
  --user        Install into ~/Applications/ContextRing.app (no admin password needed)
  -h, --help    Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --universal)
      UNIVERSAL=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --no-launch)
      NO_LAUNCH=true
      shift
      ;;
    --user)
      USER_INSTALL=true
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

if [ "$SKIP_BUILD" = false ] || [ ! -d "$BUILD_APP" ]; then
  msg "Building ContextRing.app..." "Собираю ContextRing.app..."
  if [ "$UNIVERSAL" = true ]; then
    "$ROOT_DIR/build.sh" --universal
  else
    "$ROOT_DIR/build.sh"
  fi
fi

if [ ! -d "$BUILD_APP" ]; then
  msg "Error: build output not found at $BUILD_APP" "Ошибка: не найдена сборка $BUILD_APP" >&2
  exit 1
fi

is_running() {
  /usr/bin/lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null | /usr/bin/grep -q '^ASN:' || pgrep -x ContextRing >/dev/null 2>&1
}

if is_running; then
  msg "Stopping running ContextRing..." "Останавливаю запущенный ContextRing..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! is_running; then
      break
    fi
    sleep 0.1
  done
  if is_running; then
    pkill -x ContextRing 2>/dev/null || true
    sleep 0.2
  fi
fi

if [ "$USER_INSTALL" = true ]; then
  TARGET_DIR="$HOME/Applications"
  TARGET_APP="$TARGET_DIR/ContextRing.app"
fi

admin_install() {
  local src="$1"
  local dst="$2"
  local src_escaped="${src//\'/\'\\\'\'}"
  local dst_escaped="${dst//\'/\'\\\'\'}"
  local cmd="rm -rf '${dst_escaped}' && cp -R '${src_escaped}' '${dst_escaped}' && chown -R root:admin '${dst_escaped}' && chmod -R a+rX '${dst_escaped}' && xattr -dr com.apple.quarantine '${dst_escaped}' 2>/dev/null || true"

  if command -v osascript >/dev/null 2>&1; then
    if osascript -e 'on run argv' -e 'do shell script (item 1 of argv) with administrator privileges' -e 'end run' "$cmd" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if id -Gn 2>/dev/null | grep -qw admin; then
    sudo sh -c "$cmd"
    return $?
  fi

  return 1
}

msg "Installing to $TARGET_APP..." "Устанавливаю в $TARGET_APP..."
if [ "$USER_INSTALL" = true ]; then
  mkdir -p "$TARGET_DIR"
  rm -rf "$TARGET_APP"
  cp -R "$BUILD_APP" "$TARGET_APP"
  chmod -R a+rX "$TARGET_APP" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
elif [ -w "$TARGET_DIR" ] && { [ ! -e "$TARGET_APP" ] || [ -w "$TARGET_APP" ]; }; then
  rm -rf "$TARGET_APP"
  cp -R "$BUILD_APP" "$TARGET_APP"
  chmod -R a+rX "$TARGET_APP" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
else
  msg "Administrator privileges required for /Applications..." "Для установки в /Applications требуются права администратора..."
  if ! admin_install "$BUILD_APP" "$TARGET_APP"; then
    msg "Admin authentication cancelled or unavailable. Falling back to $HOME/Applications/ContextRing.app..." \
        "Авторизация администратора отменена или недоступна. Устанавливаю в $HOME/Applications/ContextRing.app..."
    TARGET_DIR="$HOME/Applications"
    TARGET_APP="$TARGET_DIR/ContextRing.app"
    mkdir -p "$TARGET_DIR"
    rm -rf "$TARGET_APP"
    cp -R "$BUILD_APP" "$TARGET_APP"
    chmod -R a+rX "$TARGET_APP" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
  fi
fi

if [ "$NO_LAUNCH" = false ]; then
  open "$TARGET_APP"
fi

msg "Installed: $TARGET_APP" "Установлено: $TARGET_APP"
msg "Tip: for automatic Antigravity window tracking and AX Send-button snapping, grant Accessibility in:" \
    "Подсказка: для автоматического отслеживания окна Antigravity и привязки к кнопке Отправить выдай доступ:"
msg "  System Settings -> Privacy & Security -> Accessibility -> ContextRing" \
    "  Системные настройки -> Конфиденциальность и безопасность -> Универсальный доступ -> ContextRing"
