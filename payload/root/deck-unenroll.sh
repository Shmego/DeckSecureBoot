#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

KEYDIR="${DECK_SB_KEYDIR}"
if ! sb_require_efivars; then
  exit 1
fi

sb_unlock_efi_vars

CHANGED=0
if efi-updatevar -d 0 -k "$KEYDIR/PK.key" PK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/KEK.key" KEK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/db.key" db 2>/dev/null; then CHANGED=1; fi

if [ "$CHANGED" -eq 1 ]; then
  sb_pending_mark disable
  sb_report "Secure Boot vars cleared" "$(printf '%s\n\n%s' \
    "Reboot to confirm." \
    "To fully remove Deck SB, choose 'Reinstall/Remove Deck SB Jump Loader' from the menu to remove the boot entry.")"
else
  sb_report "No changes" "No Secure Boot vars were cleared (nothing changed)."
fi
