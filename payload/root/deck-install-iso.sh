#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
. /root/deck-env.sh

BACKTITLE="${DECK_SB_BACKTITLE}"
ISO_RELATIVE_PATH="/usr/local/share/deck-sb"
ISO_VOLUME_LABEL="${DECK_SB_ISO_LABEL:-DECK_SB}"
ISO_INSTALL_DIR="${DECK_SB_INSTALL_DIR:-arch}"
TEMP_ISO_MOUNT=""
declare -a ISO_TEMP_MOUNTS=()
REQUIRED_MB=400
ISO_DEBUG_LOG="$DECK_SB_DEBUG_LOG"

copy_iso_payload() {
  local rootmp="$1"
  local dest="$rootmp$ISO_RELATIVE_PATH"
  mkdir -p "$dest"

  local avail
  avail=$(df -m --output=avail "$dest" | tail -n1 | tr -d ' ')
  if [ -n "$avail" ] && [ "$avail" -lt "$REQUIRED_MB" ]; then
    sb_error "SteamOS partition has only ${avail}MB free; ${REQUIRED_MB}MB required."
    return 1
  fi

  local kernel_src
  local initrd_src
  local squash_src
  local mounted_iso=""

  mounted_iso=$(mount_live_iso_device 2>/dev/null || true)
  if [ -n "$mounted_iso" ] && [ -d "$mounted_iso" ]; then
    DECK_SB_ISO_ROOT="$mounted_iso"
    log_debug "copy_iso_payload: mounted_iso=$mounted_iso"
  fi
  kernel_src=$(find_kernel_source 2>/dev/null || true)
  initrd_src=$(find_initrd_source 2>/dev/null || true)
  squash_src=$(find_squashfs_source 2>/dev/null || true)

  log_debug "copy_iso_payload: initial sources k=${kernel_src:-none} i=${initrd_src:-none} s=${squash_src:-none}"
  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    find_iso_payload_sources kernel_src initrd_src squash_src || true
  fi

  if [ -z "$kernel_src" ] || [ -z "$initrd_src" ] || [ -z "$squash_src" ]; then
    log_debug "copy_iso_payload: final sources missing k=${kernel_src:-none} i=${initrd_src:-none} s=${squash_src:-none}"
    local debug_hint="Sources: k=${kernel_src:-none}, i=${initrd_src:-none}, s=${squash_src:-none}\nISO root: ${DECK_SB_ISO_ROOT:-none}\nLog: $ISO_DEBUG_LOG"
    sb_error "Live ISO files missing. Ensure the Secure Boot USB (${ISO_VOLUME_LABEL}) is connected and readable.\n\n${debug_hint}"
    return 1
  fi

  local arch_dir="$dest/arch"
  local boot_dir="$arch_dir/boot/x86_64"
  local sfs_dir="$arch_dir/x86_64"
  mkdir -p "$boot_dir" "$sfs_dir"

  local files=(
    "$kernel_src" "$boot_dir/vmlinuz-linux"
    "$initrd_src" "$boot_dir/initramfs-linux.img"
    "$squash_src" "$sfs_dir/airootfs.sfs"
  )

  local fifo="$(mktemp -u)"
  mkfifo "$fifo"
  deck_dialog --backtitle "$BACKTITLE" --gauge "Copying Secure Boot ISO files (~${REQUIRED_MB}MB)..." 8 70 0 <"$fifo" &
  local gauge_pid=$!
  exec 3>"$fifo"
  local i progress=0 step=$(( 100 / (${#files[@]} / 2) ))
  for ((i=0; i<${#files[@]}; i+=2)); do
    printf '%s\n' "$progress" >&3
    install -m 0644 "${files[i]}" "${files[i+1]}" || {
      printf '100\n' >&3
      exec 3>&-
      wait "$gauge_pid" 2>/dev/null || true
      rm -f "$fifo"
      sb_error "Failed copying ${files[i]} to ${files[i+1]}"
      return 1
    }
    progress=$((progress + step))
  done
  printf '100\n' >&3
  exec 3>&-
  wait "$gauge_pid" 2>/dev/null || true
  rm -f "$fifo"

  cat <<'README' > "$dest/README.txt"
Deck Secure Boot Tools
======================
These files enable booting the Secure Boot ISO directly from disk.
Remove /usr/local/share/deck-sb to reclaim space once no longer needed.
Files mirror the standard Arch ISO layout under /usr/local/share/deck-sb/arch/.
README

  return 0
}

main() {
  log_debug "==== deck-install-iso start ===="
  log_debug "lsblk snapshot:"
  LSBLK_SNAPSHOT=$(lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT -P 2>/dev/null || true)
  if [ -n "$LSBLK_SNAPSHOT" ]; then
    printf '%s\n' "$LSBLK_SNAPSHOT" | tee -a "$ISO_DEBUG_LOG" >&2 || true
  else
    log_debug "lsblk snapshot: (no output)"
  fi

  trap cleanup_temp_iso_mount EXIT

  local root_override="${1:-}" realroot
  if [ -n "$root_override" ]; then
    realroot="$root_override"
  else
    realroot=$(find_steamos_root 2>/dev/null || true)
  fi

  if [ -z "$realroot" ]; then
    sb_error "Could not detect a SteamOS root partition. Mount it manually and retry."
    exit 1
  fi

  local pretty_root
  pretty_root=$(format_display_path "$realroot")
  sb_info "SteamOS root detected at $pretty_root."

  if [ -d "$realroot$ISO_RELATIVE_PATH" ]; then
    if ! deck_dialog --backtitle "$BACKTITLE" --yesno "Existing files found in $ISO_RELATIVE_PATH. Overwrite them?" 10 70; then
      exit 0
    fi
  fi

  if ! prepare_steamos_root_for_write "$realroot"; then
    sb_error "Unable to remount $pretty_root writable."
    exit 1
  fi

  if copy_iso_payload "$realroot"; then
    sb_info "Secure Boot ISO files are ready under $(format_display_path "$realroot$ISO_RELATIVE_PATH")."
  else
    exit 1
  fi
}

main "$@"
