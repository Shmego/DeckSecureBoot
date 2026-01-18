#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

KEYDIR="${DECK_SB_KEYDIR}"
PENDING_FLAG="${DECK_SB_PENDING_FLAG}"
GUID_FILE="/var/lib/sbctl/GUID"

clean_sbctl_output() {
  local cleaned
  cleaned=$(printf '%s' "$1" | sanitize_printable)
  printf '%s\n' "$cleaned" | sed -E 's/microsoft/Microsoft/Ig'
}

exit_if_not_setup_mode() {
  if secure_boot_enabled; then
    sb_report "Secure Boot already enabled" "$(printf '%s\n%s' \
      "System not in setup mode. Secure Boot is already enabled." \
      "Use 'Disable Secure Boot' first if you need to reinstall or replace keys.")"
    exit 0
  fi
}

exit_if_not_setup_mode

for f in PK.key PK.pem KEK.key KEK.pem db.key db.pem; do
  if [ ! -f "$KEYDIR/$f" ]; then
    sb_error "Missing key file: $KEYDIR/$f"
    exit 1
  fi
done

if [ ! -d /sys/firmware/efi/efivars ]; then
  sb_error "UEFI/efivars not present"
  exit 1
fi

mkdir -p /var/lib/sbctl

mkdir -p /var/lib/sbctl/keys/PK /var/lib/sbctl/keys/KEK /var/lib/sbctl/keys/db
cp "$KEYDIR/PK.key"  /var/lib/sbctl/keys/PK/PK.key
cp "$KEYDIR/PK.pem"  /var/lib/sbctl/keys/PK/PK.pem
cp "$KEYDIR/KEK.key" /var/lib/sbctl/keys/KEK/KEK.key
cp "$KEYDIR/KEK.pem" /var/lib/sbctl/keys/KEK/KEK.pem
cp "$KEYDIR/db.key"  /var/lib/sbctl/keys/db/db.key
cp "$KEYDIR/db.pem"  /var/lib/sbctl/keys/db/db.pem

chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}* 2>/dev/null || true

if [ ! -s "$GUID_FILE" ]; then
  sb_error "sbctl GUID file missing at $GUID_FILE"
  exit 1
fi

if ! ENROLL_RAW=$(sb_run_capture "sbctl enroll-keys" sbctl enroll-keys -m); then
  cleaned=$(clean_sbctl_output "$ENROLL_RAW")
  sb_error "$(printf '%s\n%s' "sbctl enroll-keys failed:" "$cleaned")"
  exit 1
fi

cleaned=$(clean_sbctl_output "$ENROLL_RAW")

mkdir -p "$(dirname "$PENDING_FLAG")"
echo enable > "$PENDING_FLAG"

sb_report "Keys enrolled: Deck SB + Microsoft" "$(printf '%s\n\n%s\n\n%s' \
  "$cleaned" \
  "Next Step: Select 'Install Deck SB Jump Loader' from the menu to install the signed Deck SB EFI and boot menu entries. (Required for SteamOS to boot under Secure Boot.)" \
  "Reminder: Unsigned EFIs (including Clover) will NOT boot under Secure Boot until you sign them. Use the 'Signing Utility' from the menu to sign additional EFIs.")"
