#!/bin/bash
set -euo pipefail
export DIALOGRC=/etc/dialogrc

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
ISO_DEBUG_LOG="$DECK_SB_DEBUG_LOG"
SHOW_LOG_MENU="${DECK_SB_DEBUG:-0}"

open_shell() {
  hostname deck-sb 2>/dev/null || true
  clear
  cat <<EOM
=========================================
 DeckSB Manager v${DECK_SB_VERSION} - Root Shell
 To go back to menu: /root/menu.sh
=========================================
EOM
  exec /bin/bash
}

view_iso_debug_log() {
  if [ ! -s "$ISO_DEBUG_LOG" ]; then
    deck_dialog --msgbox "ISO debug log not found or empty at $ISO_DEBUG_LOG." 10 70
    return
  fi
  deck_dialog --textbox "$ISO_DEBUG_LOG" 22 90
}

run_menu_action() {
  local title="$1"
  shift
  local status reason
  sb_clear_error
  if DECK_SB_MENU_CONTEXT=1 "$@"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    if reason=$(sb_get_error 2>/dev/null); then
      reason=$(printf '%s' "$reason" | sanitize_printable)
      deck_message_box "$title failed (exit $status)" "$reason" 18 90
    else
      deck_message_box "$title failed (exit $status)" "No error details captured." 10 70
    fi
  fi
  return 0
}

while true; do
  PEND=$(sb_pending_suffix)
  JUMP_LABEL="Install Deck SB Jump Loader"
  if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
    JUMP_LABEL="Reinstall/Remove Deck SB Jump Loader"
  fi
  MENU_ITEMS=(
    1 "Check Boot Status${PEND}"
    2 "Enable Secure Boot"
    3 "$JUMP_LABEL"
    4 "Install Deck SB ISO to disk *Optional* (~400MB)"
    5 "Signing Utility"
  )
  if [ "$SHOW_LOG_MENU" -eq 1 ]; then
    MENU_ITEMS+=(6 "View ISO debug log")
  fi
  MENU_ITEMS+=(
    7 "--------------------------------"
    8 "Reboot"
    9 "Poweroff"
    10 "Open root shell (requires USB keyboard)"
    11 "Disable Secure Boot"
  )

  if ! CHOICE=$(deck_dialog --clear --stdout \
      --title "Main Menu" \
      --menu "Select an action" 0 0 0 "${MENU_ITEMS[@]}"); then
    continue
  fi

  case "$CHOICE" in
    1) run_menu_action "Check Boot Status" /root/deck-status.sh ;;
    2) run_menu_action "Enable Secure Boot" /root/deck-enroll.sh ;;
    3)
      if /root/deck-install-jump.sh --detect-installed >/dev/null 2>&1; then
        SUB=$(deck_dialog --clear --stdout --default-item 1 \
          --menu "Deck SB Jump Loader" 0 0 0 \
          1 "Reinstall jump loader" \
          2 "Remove jump loader") || continue
        case "$SUB" in
          1) run_menu_action "Reinstall jump loader" /root/deck-install-jump.sh ;;
          2) run_menu_action "Remove jump loader" /root/deck-install-jump.sh --remove ;;
        esac
      else
        run_menu_action "Install jump loader" /root/deck-install-jump.sh
      fi
      ;;
    4) run_menu_action "Install Deck SB ISO" /root/deck-install-iso.sh ;;
    5) run_menu_action "Signing Utility" /root/deck-sign-efi.sh ;;
    6) view_iso_debug_log ;;
    7) : ;;
    8) reboot ;;
    9) poweroff ;;
    10) open_shell ;;
    11) run_menu_action "Disable Secure Boot" /root/deck-unenroll.sh ;;
  esac
done
