#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

FIND_TIMEOUT=${FIND_TIMEOUT:-15}
TIMEOUT_BIN=$(command -v timeout || true)

ISO_MOUNT="${DECK_SB_ISO_MOUNT}"
TMP_EFI_MOUNT_BASE="${DECK_SB_TMP_EFI_MOUNT_BASE}"
TMP_LINUX_MOUNT_BASE="${DECK_SB_TMP_LINUX_MOUNT_BASE}"
mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"
CLOVER_BUNDLE_KEY="__CLOVER_BUNDLE__"

LINUX_FSTYPES='ext2|ext3|ext4|btrfs|xfs|f2fs'
LINUX_GPT_GUIDS=(
  0FC63DAF-8483-4772-8E79-3D69D8477DE4  # Linux filesystem data
  44479540-F297-41B2-9AF7-D131D5F0458A  # Linux root (x86)
  4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709  # Linux root (x86-64)
)

SEARCH_DIRS=()
TEMP_MOUNTS=()
declare -A ADDED_DIRS=()
declare -A SEEN_FILES=()

cleanup() {
  cleanup_mounts TEMP_MOUNTS
}
trap cleanup EXIT

seed_default_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "$ISO_MOUNT"
progress_msg() {
  local msg="$1"
  sb_progress "$msg" 5 70
}

progress_msg "Scanning disks for EFI files and kernels..."
declare -A ISO_SKIP_MAP=()
collect_iso_device_skip_map "ISO_SKIP_MAP"
collect_device_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "TEMP_MOUNTS" "$ISO_MOUNT" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE" progress_msg "ISO_SKIP_MAP"

ALL=()

for dir in "${SEARCH_DIRS[@]}"; do
  while IFS= read -r -d '' f; do
    add_unique_file "ALL" "SEEN_FILES" "$ISO_MOUNT" "$f"
  done < <(run_find_timeout "$dir" 4 -type f -iname '*.efi' || true)
  while IFS= read -r -d '' k; do
    add_unique_file "ALL" "SEEN_FILES" "$ISO_MOUNT" "$k"
  done < <(run_find_timeout "$dir" 8 -type f -iname 'vmlinuz*' || true)
done
deck_dialog --clear

ALL=("${ALL[@]}")

loader_variant_label() {
  local lower="$1"
  if [[ "$lower" == *mmx64*.efi* ]]; then
    echo "MokManager"
  elif [[ "$lower" == *shimx64*.efi* ]]; then
    echo "Shim"
  elif [[ "$lower" == *grubx64*.efi* ]]; then
    echo "GRUB"
  else
    echo ""
  fi
}

sign_clover_bundle() {
  local files=("$@")
  if [ "${#files[@]}" -eq 0 ]; then
    deck_dialog --msgbox "No Clover EFI files were detected." 8 60
    return 0
  fi

  local file display
  for file in "${files[@]}"; do
    display=$(deck_display_path "$file")
    if ! ERR=$(ensure_rw_for_path "$file"); then
      deck_dialog --msgbox "${ERR:-Unable to access $display.}" 9 70
      return 1
    fi
  done

  local summary=""
  local success=0 already=0 failed=0
  for file in "${files[@]}"; do
    display=$(deck_display_path "$file")
    deck_dialog --infobox "Signing Clover EFI:\n$display" 6 70
    sbctl_sign_analyze "$file"
    case "$SBCTL_RESULT" in
      signed)
        summary+="$display: signed\n"
        success=$((success + 1))
        ;;
      already)
        summary+="$display: already signed\n"
        already=$((already + 1))
        ;;
      *)
        summary+="$display: FAILED (exit $SBCTL_STATUS)\n$SBCTL_CLEAN_OUTPUT\n\n"
        failed=$((failed + 1))
        ;;
    esac
  done

  summary=$(printf '%s' "$summary" | sanitize_printable)
  local heading
  if [ $failed -eq 0 ]; then
    heading="Clover EFIs signing summary (signed: $success, already: $already)"
  else
    heading="Clover EFIs signing summary (signed: $success, already: $already, failed: $failed)"
  fi
  deck_dialog --msgbox "$(printf '%s\n\n%s' "$heading" "$summary")" 20 90
  return 0
}

guess_kind() {
  local path="$1"
  local lower="${path,,}"
  local variant label
  variant=$(loader_variant_label "$lower")

  if [[ "$lower" == *steamcl*.efi ]]; then
    label="SteamOS (Default)"
  elif [[ "$lower" == *efi/steamos/* && "$lower" == *grub*.efi* ]]; then
    label="SteamOS (GRUB)"
  elif [[ "$lower" == *efi/steamos/* ]]; then
    label="SteamOS loader"
  elif [[ "$lower" == *vmlinuz* ]]; then
    label="Linux kernel"
  elif [[ "$lower" == *ubuntu* ]]; then
    label=${variant:+Ubuntu $variant}
    [ -n "$label" ] || label="Ubuntu loader"
  elif [[ "$lower" == *fedora* ]]; then
    label=${variant:+Fedora $variant}
    [ -n "$label" ] || label="Fedora loader"
  elif [[ "$lower" == *microsoft* || "$lower" == *bootmgfw.efi* ]]; then
    label="Windows bootmgfw"
  elif [[ "$lower" == *efi/boot/bootx64.efi* ]]; then
    label="Generic UEFI bootloader"
  elif [ -n "$variant" ]; then
    label="$variant"
  else
    label="Unknown EFI"
  fi

  echo "$label"
}

if [ "${#ALL[@]}" -eq 0 ]; then
  if [ "${#SEARCH_DIRS[@]}" -gt 0 ]; then
    checked_dirs=$(printf "%s " "${SEARCH_DIRS[@]}")
  else
    checked_dirs="(no candidate directories)"
  fi

  sb_error "No EFI files were found.\nChecked: ${checked_dirs}.\nMount your target ESP and try again." 11 74
  exit 1
fi

while true; do
  MENU=()
  PICK_TARGETS=()
  i=1
  STEAM_CAND=()
  OTHER_CAND=()
  for c in "${ALL[@]}"; do
    if [[ "$c" == *EFI/steamos/* || "$c" == *EFI/STEAMOS/* || "$c" == *steamcl*.efi ]]; then
      STEAM_CAND+=("$c")
    elif [[ "$c" == *vmlinuz* ]]; then
      STEAM_CAND+=("$c")
    else
      OTHER_CAND+=("$c")
    fi
  done

  ORDERED=("${STEAM_CAND[@]}" "${OTHER_CAND[@]}")

  CLOVER_FILES=()
  NON_CLOVER_ORDERED=()
  for c in "${ORDERED[@]}"; do
    lower_val=${c,,}
    if [[ "$lower_val" == *clover* ]]; then
      CLOVER_FILES+=("$c")
    else
      NON_CLOVER_ORDERED+=("$c")
    fi
  done

  if [ "${#CLOVER_FILES[@]}" -gt 0 ]; then
    MENU+=("$i" "Clover EFIs :: ${#CLOVER_FILES[@]} file(s)")
    PICK_TARGETS+=("$CLOVER_BUNDLE_KEY")
    i=$((i+1))
  fi

  for c in "${NON_CLOVER_ORDERED[@]}"; do
    KIND=$(guess_kind "$c")
    DISPLAY_PATH=$(deck_display_path "$c")
    MENU+=("$i" "$KIND :: $DISPLAY_PATH")
    PICK_TARGETS+=("$c")
    i=$((i+1))
  done

  if [ "${#PICK_TARGETS[@]}" -eq 0 ]; then
    sb_info "No signable files were found." 8 60
    break
  fi

  CHOICE=$(deck_dialog --clear --stdout --cancel-label "Back" --menu "Select EFI / kernel to sign" 0 0 0 "${MENU[@]}") || break
  TARGET_KEY="${PICK_TARGETS[$((CHOICE-1))]}"

  if [ "$TARGET_KEY" = "$CLOVER_BUNDLE_KEY" ]; then
    if ! sign_clover_bundle "${CLOVER_FILES[@]}"; then
      continue
    fi
    continue
  fi

  TARGET="$TARGET_KEY"

  if ! ERR=$(ensure_rw_for_path "$TARGET"); then
    deck_dialog --msgbox "${ERR:-Unable to access target.}" 8 70
    continue
  fi

  lower_target=${TARGET,,}
  if [[ "$lower_target" == *microsoft* || "$lower_target" == *bootmgfw.efi* ]]; then
    deck_dialog --yesno "This looks like a Windows EFI loader.\nRe-signing this EFI is not recommended.\nContinue anyway?" 12 60 || continue
  fi

  deck_dialog --infobox "Signing:\n$TARGET" 6 70
  sbctl_sign_analyze "$TARGET"
  case "$SBCTL_RESULT" in
    signed)
      deck_message_box "Signing succeeded" "$SBCTL_CLEAN_OUTPUT"
      ;;
    already)
      deck_message_box "Already signed" "$SBCTL_CLEAN_OUTPUT"
      ;;
    *)
      deck_message_box "Signing failed (exit $SBCTL_STATUS)" "$SBCTL_CLEAN_OUTPUT"
      ;;
  esac
done

exit 0
