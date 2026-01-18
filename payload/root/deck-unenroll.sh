#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

KEYDIR="${DECK_SB_KEYDIR}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"
if [ ! -d /sys/firmware/efi/efivars ]; then
  sb_error "UEFI/efivars not present"
  exit 1
fi

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

CHANGED=0
if efi-updatevar -d 0 -k "$KEYDIR/PK.key" PK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/KEK.key" KEK 2>/dev/null; then CHANGED=1; fi
if efi-updatevar -d 0 -k "$KEYDIR/db.key" db 2>/dev/null; then CHANGED=1; fi

if [ "$CHANGED" -eq 1 ]; then
  mkdir -p "$(dirname "$PENDING_FLAG")"
  echo disable > "$PENDING_FLAG"
  sb_report "Secure Boot vars cleared" "$(printf '%s\n\n%s' \
    "Reboot to confirm." \
    "To fully remove Deck SB, choose 'Reinstall/Remove Deck SB Jump Loader' from the menu to remove the boot entry.")"
else
  sb_report "No changes" "No Secure Boot vars were cleared (nothing changed)."
fi
