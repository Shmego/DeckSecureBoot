#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091

. /root/deck-env.sh

TARGET_FILENAME="$DECK_SB_TARGET_FILENAME"
OLD_EFI_LABEL="$DECK_SB_OLD_EFI_LABEL"  # legacy label to clean up
NEW_EFI_LABEL="$DECK_SB_NEW_EFI_LABEL"
DECK_SB_FILES_DIR="/root/deck-sb-files"
JUMP_SOURCE="$DECK_SB_FILES_DIR/steamos-jump.signed.efi"
PNG_SOURCE="$DECK_SB_FILES_DIR/deckpink.png"
CLOVER_ENTRY_TEMPLATE="$DECK_SB_FILES_DIR/clover-jump-entry.plist"
DECK_SB_CFG_TEMPLATE="$DECK_SB_FILES_DIR/deck-sb.cfg.tmpl"
DEFAULT_KERNEL_IMAGE="/boot/vmlinuz-linux-neptune-611"
DEFAULT_INITRD_IMAGES="/boot/amd-ucode.img /boot/initramfs-linux-neptune-611.img"
STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
STEAMOS_KERNEL_VERBOSITY="loglevel=3 quiet splash"
BOOT_LABELS=("$NEW_EFI_LABEL" "$OLD_EFI_LABEL")

ISO_MOUNT="${DECK_SB_ISO_MOUNT}"
TMP_EFI_MOUNT_BASE="${DECK_SB_TMP_EFI_MOUNT_BASE}"
TMP_LINUX_MOUNT_BASE="${DECK_SB_TMP_LINUX_MOUNT_BASE}"
JUMP_STATE_FILE="${DECK_SB_JUMP_STATE_FILE:-/run/deck-sb/jump.state}"

LINUX_FSTYPES='ext2|ext3|ext4|btrfs|xfs|f2fs'
LINUX_GPT_GUIDS=(
  0FC63DAF-8483-4772-8E79-3D69D8477DE4
  44479540-F297-41B2-9AF7-D131D5F0458A
  4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
)

if [ "${DECK_SB_DEBUG:-0}" -eq 1 ]; then
  STEAMOS_KERNEL_VERBOSITY="loglevel=5"
fi

mkdir -p "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE"

cleanup() {
  cleanup_mounts TEMP_MOUNTS
}

clean_source_path() {
  local src="$1"
  case "$src" in
    *'['*) src="${src%%[*}" ;;
  esac
  echo "$src"
}

trim_config_value() {
  local val="$1"
  printf '%s\n' "$val" | awk '{sub(/\r$/, ""); sub(/[ \t]*\\$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print}'
}

record_jump_state() {
  local path="$1" state_dir
  state_dir=$(dirname "$JUMP_STATE_FILE")
  mkdir -p "$state_dir" 2>/dev/null || true
  if [ -n "$path" ]; then
    printf '%s\n' "$path" > "$JUMP_STATE_FILE"
  else
    echo "none" > "$JUMP_STATE_FILE"
  fi
}

read_jump_state() {
  [ -f "$JUMP_STATE_FILE" ] || return 1
  local state
  state=$(tr -d '\r\n' < "$JUMP_STATE_FILE" 2>/dev/null || true)
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
  return 0
}

parse_kernel_initrd_from_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1

  local kernel_image initrd_images updated=0

  kernel_image=$(awk '
    {
      cmd = tolower($1)
      if (cmd == "linux" || cmd == "linuxefi") {
        print $2
        exit
      }
    }
  ' "$cfg" 2>/dev/null || true)
  kernel_image=$(trim_config_value "$kernel_image")
  if [ -n "$kernel_image" ]; then
    STEAMOS_KERNEL_IMAGE="$kernel_image"
    updated=1
  fi

  initrd_images=$(awk '
    {
      cmd = tolower($1)
      if (cmd == "initrd" || cmd == "initrdefi") {
        $1 = ""
        sub(/^[\t ]+/, "")
        print
        exit
      }
    }
  ' "$cfg" 2>/dev/null || true)
  initrd_images=$(trim_config_value "$initrd_images")
  if [ -n "$initrd_images" ]; then
    STEAMOS_INITRD_IMAGES="$initrd_images"
    updated=1
  fi

  [ "$updated" -eq 1 ] || return 1
  return 0
}

find_partsets_dir() {
  local base="$1"
  local rel
  for rel in "SteamOS/partsets" "EFI/SteamOS/partsets" "efi/SteamOS/partsets"; do
    if [ -d "$base/$rel" ]; then
      printf '%s\n' "$base/$rel"
      return 0
    fi
  done
  if command -v find >/dev/null 2>&1; then
    local found
    found=$(find "$base" -maxdepth 8 -type f -path '*/SteamOS/partsets/self' -print -quit 2>/dev/null || true)
    if [ -n "$found" ]; then
      printf '%s\n' "$(dirname "$found")"
      return 0
    fi
  fi
  return 1
}

read_partset_value() {
  local file="$1" key="$2"
  local value=""
  [ -f "$file" ] || return 1

  value=$(awk -v key="$key" '
function is_hex_uuid(v, parts, n) {
  if (length(v) != 36) return 0
  if (v !~ /^[0-9a-f-]+$/) return 0
  n = split(v, parts, "-")
  if (n != 5) return 0
  if (length(parts[1]) != 8) return 0
  if (length(parts[2]) != 4) return 0
  if (length(parts[3]) != 4) return 0
  if (length(parts[4]) != 4) return 0
  if (length(parts[5]) != 12) return 0
  return 1
}

function emit_if_uuid(v) {
  gsub(/^[^0-9A-Fa-f-]+/, "", v)
  gsub(/[^0-9A-Fa-f-]+$/, "", v)
  v = tolower(v)
  if (is_hex_uuid(v)) {
    print v
    found = 1
  }
}

BEGIN {
  key = tolower(key)
}

{
  if (found) next
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[[:space:]]*#/) next
  sub(/[[:space:]]+#.*$/, "", line)
  if (line ~ /^[[:space:]]*$/) next

  line_lc = tolower(line)
  if (line_lc !~ ("(^|[^[:alnum:]_])" key "([^[:alnum:]_]|$)")) next

  if (match(line_lc, /partuuid=[^[:space:]\",;]+/)) {
    emit_if_uuid(substr(line_lc, RSTART + 9, RLENGTH - 9))
    if (found) exit
  }
  if (match(line_lc, /by-partuuid\/[^[:space:]\",;]+/)) {
    emit_if_uuid(substr(line_lc, RSTART + 12, RLENGTH - 12))
    if (found) exit
  }
  if (match(line_lc, /uuid=[^[:space:]\",;]+/)) {
    emit_if_uuid(substr(line_lc, RSTART + 5, RLENGTH - 5))
    if (found) exit
  }

  count = split(line_lc, tokens, /[^0-9a-f-]+/)
  for (i = 1; i <= count; i++) {
    emit_if_uuid(tokens[i])
    if (found) exit
  }
}
' "$file" 2>/dev/null || true)

  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
  return 0
}

read_partset_rootfs_partuuid() {
  local file="$1"
  [ -f "$file" ] || return 1
  read_partset_value "$file" "rootfs"
}

find_partsets_for_custom_dir() {
  local custom_dir="$1"
  local esp_root=""
  local partsets_dir=""

  esp_root=$(findmnt -rno TARGET -T "$custom_dir" 2>/dev/null || true)
  if [ -z "$esp_root" ]; then
    esp_root=$(dirname "$(dirname "$custom_dir")")
  fi
  partsets_dir=$(find_partsets_dir "$esp_root" 2>/dev/null || true)
  if [ -z "$partsets_dir" ] && [ -n "${TMP_EFI_MOUNT_BASE:-}" ]; then
    partsets_dir=$(find_partsets_dir "$TMP_EFI_MOUNT_BASE" 2>/dev/null || true)
  fi
  if [ -z "$partsets_dir" ] && [ -n "${TMP_LINUX_MOUNT_BASE:-}" ]; then
    partsets_dir=$(find_partsets_dir "$TMP_LINUX_MOUNT_BASE" 2>/dev/null || true)
  fi
  if [ -n "$partsets_dir" ]; then
    log_debug "partsets: $partsets_dir"
  else
    log_debug "partsets: missing"
  fi
  printf '%s\n' "$partsets_dir"
  return 0
}

find_esp_root_for_custom_dir() {
  local custom_dir="$1"
  local esp_root=""

  esp_root=$(findmnt -rno TARGET -T "$custom_dir" 2>/dev/null || true)
  if [ -z "$esp_root" ]; then
    esp_root=$(dirname "$(dirname "$custom_dir")")
  fi
  printf '%s\n' "$esp_root"
  return 0
}

sign_kernel_on_partuuid() {
  local partuuid="$1" label="$2"
  local dev="" fstype="" top_mount="" root_mount="" root_path="" subvol_rel="" ro_state="" ro_changed=0

  if [ -z "$partuuid" ]; then
    log_debug "sign: $label missing partuuid"
    return 1
  fi
  log_debug "sign: $label begin for partuuid $partuuid"

  dev=$(readlink -f "/dev/disk/by-partuuid/$partuuid" 2>/dev/null || true)
  if [ ! -b "$dev" ]; then
    dev=$(readlink -f "/dev/disk/by-partuuid/${partuuid^^}" 2>/dev/null || true)
  fi
  if [ ! -b "$dev" ]; then
    log_debug "sign: $label partuuid $partuuid not found"
    return 1
  fi
  local dev_ro=""
  dev_ro=$(lsblk -nrpo RO "$dev" 2>/dev/null | head -n1 || true)
  log_debug "sign: $label device $dev ro flag: ${dev_ro:-unknown}"

  fstype=$(lsblk -nrpo FSTYPE "$dev" 2>/dev/null | head -n1 || true)
  fstype=${fstype,,}
  top_mount=$(mktemp -d /run/deck-sb-top.XXXXXX)
  root_mount=$(mktemp -d /run/deck-sb-root.XXXXXX)

  if [ "$fstype" = "btrfs" ]; then
    log_debug "sign: $label mounting top-level $dev at $top_mount"
    if ! mount -o subvolid=5 "$dev" "$top_mount"; then
      log_debug "sign: $label failed to mount top-level $dev"
      rmdir "$top_mount" "$root_mount" 2>/dev/null || true
      return 1
    fi
    log_debug "sign: $label mounted top-level at $top_mount"
    log_debug "sign: $label top-level mount opts: $(findmnt -nr -o OPTIONS -T "$top_mount" 2>/dev/null || true)"

    root_path=$(locate_steamos_root_within "$top_mount" "$fstype" 2>/dev/null || true)
    if [ -z "$root_path" ]; then
      log_debug "sign: $label SteamOS root not found in $dev"
      if [ "${DECK_SB_DEBUG:-0}" -eq 1 ]; then
        log_debug "sign: $label subvolumes under $dev:"
        while IFS= read -r line; do
          log_debug "sign: $label subvol $line"
        done < <(btrfs subvolume list "$top_mount" 2>/dev/null || true) || true
        log_debug "sign: $label top-level dirs:"
        while IFS= read -r line; do
          log_debug "sign: $label ls $line"
        done < <(ls -la "$top_mount" 2>/dev/null || true) || true
      fi
      umount "$top_mount" 2>/dev/null || true
      rmdir "$top_mount" "$root_mount" 2>/dev/null || true
      return 1
    fi

    if [ "$root_path" = "$top_mount" ]; then
      subvol_rel=""
      log_debug "sign: $label root path is top-level mount"
    else
      subvol_rel="${root_path#$top_mount/}"
    fi
    local ro_raw="" ro_status=0
    if ro_raw=$(btrfs property get -ts "$root_path" ro 2>&1); then
      ro_status=0
    else
      ro_status=$?
    fi
    ro_state=$(printf '%s\n' "$ro_raw" | awk -F= '/^ro=/{print $2; exit}')
    log_debug "sign: $label ro state for ${subvol_rel:-top-level} is ${ro_state:-unknown}"
    if [ -z "$ro_state" ]; then
      log_debug "sign: $label ro query exit=$ro_status"
      if [ -n "$ro_raw" ]; then
        while IFS= read -r line; do
          log_debug "sign: $label ro query: $line"
        done <<< "$ro_raw"
      fi
    fi

    if [ "$ro_state" = "true" ] || [ -z "$ro_state" ]; then
      log_debug "sign: $label setting ro=false on ${subvol_rel:-top-level}"
      if btrfs property set -ts "$root_path" ro false 2>/dev/null; then
        ro_changed=1
        log_debug "sign: $label set ro=false on ${subvol_rel:-top-level}"
      else
        log_debug "sign: $label failed to set ro=false on ${subvol_rel:-top-level}"
      fi
    fi

    if [ -n "$subvol_rel" ]; then
      log_debug "sign: $label mounting subvol $subvol_rel at $root_mount"
      if ! mount -o "subvol=$subvol_rel" "$dev" "$root_mount"; then
        log_debug "sign: $label failed to mount subvol $subvol_rel"
        if [ "$ro_changed" -eq 1 ]; then
          btrfs property set -ts "$root_path" ro true 2>/dev/null || true
        fi
        umount "$top_mount" 2>/dev/null || true
        rmdir "$top_mount" "$root_mount" 2>/dev/null || true
        return 1
      fi
      log_debug "sign: $label mounted subvol at $root_mount"
      log_debug "sign: $label subvol mount opts: $(findmnt -nr -o OPTIONS -T "$root_mount" 2>/dev/null || true)"
    else
      root_mount="$top_mount"
      log_debug "sign: $label using top-level mount as rootfs"
    fi
  else
    log_debug "sign: $label mounting $dev at $root_mount"
    if ! mount "$dev" "$root_mount"; then
      log_debug "sign: $label failed to mount $dev"
      rmdir "$top_mount" "$root_mount" 2>/dev/null || true
      return 1
    fi
    log_debug "sign: $label mounted $dev at $root_mount"
    log_debug "sign: $label mount opts: $(findmnt -nr -o OPTIONS -T "$root_mount" 2>/dev/null || true)"
  fi

  local mount_opts
  mount_opts=$(findmnt -nr -o OPTIONS -T "$root_mount" 2>/dev/null || true)
  if mount_opts_has_flag "$mount_opts" "ro"; then
    log_debug "sign: $label remounting $root_mount rw"
    if mount -o remount,rw "$root_mount" 2>/dev/null; then
      log_debug "sign: $label remount rw ok"
    else
      log_debug "sign: $label remount rw failed"
    fi
    log_debug "sign: $label mount opts after remount: $(findmnt -nr -o OPTIONS -T "$root_mount" 2>/dev/null || true)"
  fi

  local kernel_path="$root_mount$STEAMOS_KERNEL_IMAGE"
  log_debug "sign: $label kernel path $kernel_path"
  if [ -f "$kernel_path" ]; then
    log_debug "sign: $label signing $kernel_path"
    sb_run_capture "sbctl sign $label" sbctl sign -s "$kernel_path" >/dev/null || true
    log_debug "sign: $label signed $kernel_path"
  else
    log_debug "sign: $label kernel missing $kernel_path"
    if [ "${DECK_SB_DEBUG:-0}" -eq 1 ]; then
      if [ -d "$root_mount/boot" ]; then
        log_debug "sign: $label /boot listing:"
        while IFS= read -r line; do
          log_debug "sign: $label /boot $line"
        done < <(ls -la "$root_mount/boot" 2>/dev/null || true) || true
      else
        log_debug "sign: $label /boot missing under rootfs"
      fi
      log_debug "sign: $label searching for vmlinuz* under rootfs"
      while IFS= read -r line; do
        log_debug "sign: $label found $line"
      done < <(find "$root_mount" -maxdepth 3 -type f -name 'vmlinuz*' 2>/dev/null || true) || true
    fi
  fi

  if [ "$root_mount" != "$top_mount" ]; then
    log_debug "sign: $label unmounting $root_mount"
    umount "$root_mount" 2>/dev/null || true
  fi
  if [ "$fstype" = "btrfs" ]; then
    if [ "$ro_changed" -eq 1 ] && [ -n "$root_path" ]; then
      if btrfs property set -ts "$root_path" ro true 2>/dev/null; then
        log_debug "sign: $label restored ro=true on $subvol_rel"
      else
        log_debug "sign: $label failed to restore ro=true on $subvol_rel"
      fi
    fi
    log_debug "sign: $label unmounting top-level $top_mount"
    umount "$top_mount" 2>/dev/null || true
  fi
  rmdir "$top_mount" "$root_mount" 2>/dev/null || true
  return 0
}

sign_steamos_kernels_from_partsets() {
  local custom_dir="$1"
  if ! command -v sbctl >/dev/null 2>&1; then
    deck_dialog --msgbox "sbctl is not available in this environment.\nSkipping SteamOS kernel signing." 9 80
    return 0
  fi

  local partsets_dir esp_root
  partsets_dir=$(find_partsets_for_custom_dir "$custom_dir")
  esp_root=$(find_esp_root_for_custom_dir "$custom_dir")
  if [ -n "$esp_root" ]; then
    local conf_dir="" conf_file="" conf_found=0
    for conf_dir in "$esp_root/SteamOS/conf"; do
      if [ -d "$conf_dir" ]; then
        log_debug "conf: using $conf_dir"
        for conf_file in A.conf B.conf dev.conf; do
          local conf_path="$conf_dir/$conf_file"
          if [ -f "$conf_path" ]; then
            log_debug "conf: $conf_file"
            while IFS= read -r line; do
              log_debug "conf: $conf_file: $line"
            done < "$conf_path"
          else
            log_debug "conf: missing $conf_path"
          fi
        done
        conf_found=1
        break
      fi
    done
    if [ "$conf_found" -eq 0 ]; then
      log_debug "conf: missing under $esp_root"
    fi
  fi
  if [ -z "$partsets_dir" ]; then
    deck_dialog --msgbox "SteamOS partsets not found on the ESP. Skipping kernel signing." 9 80
    return 0
  fi

  local rootfs_self="" rootfs_a="" rootfs_b=""
  rootfs_self=$(read_partset_rootfs_partuuid "$partsets_dir/self" 2>/dev/null || true)
  rootfs_a=$(read_partset_rootfs_partuuid "$partsets_dir/A" 2>/dev/null || true)
  rootfs_b=$(read_partset_rootfs_partuuid "$partsets_dir/B" 2>/dev/null || true)
  if [ -n "$rootfs_self" ]; then
    if [ -n "$rootfs_a" ] && [ "$rootfs_self" = "$rootfs_a" ]; then
      log_debug "partsets: active slot A"
    elif [ -n "$rootfs_b" ] && [ "$rootfs_self" = "$rootfs_b" ]; then
      log_debug "partsets: active slot B"
    else
      log_debug "partsets: active slot unknown (self not in A/B)"
    fi
  else
    log_debug "partsets: active slot unknown (self missing)"
  fi

  if [ -z "$rootfs_a" ] && [ -z "$rootfs_b" ]; then
    deck_dialog --msgbox "SteamOS rootfs PARTUUIDs not found. Skipping kernel signing." 9 80
    return 0
  fi

  local order=()
  if [ -n "$rootfs_self" ] && [ "$rootfs_self" = "$rootfs_a" ]; then
    order=("A" "B")
  elif [ -n "$rootfs_self" ] && [ "$rootfs_self" = "$rootfs_b" ]; then
    order=("B" "A")
  else
    order=("A" "B")
  fi

  deck_dialog --infobox "Signing SteamOS kernels (active slot first)..." 6 70
  local slot partuuid sign_fail=0
  for slot in "${order[@]}"; do
    if [ "$slot" = "A" ]; then
      partuuid="$rootfs_a"
    else
      partuuid="$rootfs_b"
    fi
    [ -n "$partuuid" ] || continue
    if ! sign_kernel_on_partuuid "$partuuid" "$slot"; then
      log_debug "sign: $slot failed"
      sign_fail=1
    fi
  done
  if [ "$sign_fail" -eq 1 ]; then
    deck_dialog --msgbox "SteamOS kernel signing attempt complete.\nSome slots failed to sign; check the debug log for details." 8 80
  else
    deck_dialog --msgbox "SteamOS kernel signing attempt complete." 7 70
  fi
  return 0
}

update_kernel_initrd_from_grub() {
  local grub_path="$1"
  local steamcl_path="$2"
  local cfg

  cfg=$(find_grub_cfg_for_paths "$grub_path" "$steamcl_path" 2>/dev/null || true)
  if [ -z "$cfg" ]; then
    STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
    STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
    deck_dialog --msgbox "SteamOS grub.cfg was not found near the selected loader (e.g. steamos/grubx64.efi).\nUsing default kernel/initrd paths instead." 12 80
    return 1
  fi

  deck_dialog --infobox "Parsing kernel/initrd settings from $(deck_display_path "$cfg")..." 6 70
  if parse_kernel_initrd_from_cfg "$cfg"; then
    deck_dialog --msgbox "Kernel/initrd paths captured from $(deck_display_path "$cfg")." 8 80
    return 0
  fi

  STEAMOS_KERNEL_IMAGE="$DEFAULT_KERNEL_IMAGE"
  STEAMOS_INITRD_IMAGES="$DEFAULT_INITRD_IMAGES"
  deck_dialog --msgbox "Could not parse kernel/initrd data from $(deck_display_path "$cfg").\nUsing default kernel/initrd paths instead." 12 80
  return 1
}

scan_devices() {
  seed_default_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "$ISO_MOUNT"
  deck_dialog --infobox "Scanning disks for SteamOS loaders..." 5 70
  declare -A ISO_SKIP_MAP=()
  collect_iso_device_skip_map "ISO_SKIP_MAP"
  log_debug "scan_devices: ISO skip entries: ${!ISO_SKIP_MAP[*]}"
  collect_device_search_dirs "SEARCH_DIRS" "ADDED_DIRS" "TEMP_MOUNTS" "$ISO_MOUNT" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE" "" "ISO_SKIP_MAP"
}

collect_base_candidates() {
  BASE_CANDIDATES=()
  GRUB_CANDIDATES=()
  for dir in "${SEARCH_DIRS[@]}"; do
    while IFS= read -r -d '' f; do
      add_fat_candidate "BASE_CANDIDATES" "SEEN_BASE" "$ISO_MOUNT" "$f"
    done < <(run_find_timeout "$dir" 4 -type f -iname 'steamcl*.efi' || true)
    while IFS= read -r -d '' g; do
      add_unique_file "GRUB_CANDIDATES" "SEEN_GRUB" "$ISO_MOUNT" "$g"
    done < <(run_find_timeout "$dir" 6 -type f -path '*/EFI/steamos/grubx64.efi' || true)
  done
}

collect_kernel_candidates() {
  KERNEL_CANDIDATES=()
  SEEN_KERNELS=()
  for dir in "${SEARCH_DIRS[@]}"; do
    while IFS= read -r -d '' k; do
      add_unique_file "KERNEL_CANDIDATES" "SEEN_KERNELS" "$ISO_MOUNT" "$k"
    done < <(run_find_timeout "$dir" 8 -type f -iname 'vmlinuz*' || true)
  done
}

select_base_candidate() {
  local count=${#BASE_CANDIDATES[@]}
  if [ "$count" -eq 0 ]; then
    sb_error "Could not find any SteamOS steamcl EFI files. Mount your SteamOS installation and try again." 10 80
    exit 1
  fi
  if [ "$count" -eq 1 ]; then
    SELECTED_BASE="${BASE_CANDIDATES[0]}"
    return
  fi

  local menu=()
  local idx=1
  for cand in "${BASE_CANDIDATES[@]}"; do
    menu+=("$idx" "SteamOS base :: $(deck_display_path "$cand")")
    idx=$((idx + 1))
  done

  local choice
  choice=$(deck_dialog --stdout --cancel-label "Back" \
    --menu "Select SteamOS base loader" 0 0 0 "${menu[@]}") || exit 0

  SELECTED_BASE="${BASE_CANDIDATES[$((choice - 1))]}"
}

select_grub_for_base() {
  local steamcl_mount="$1"
  [ "${#GRUB_CANDIDATES[@]}" -eq 0 ] && { SELECTED_GRUB=""; return; }

  local g
  for g in "${GRUB_CANDIDATES[@]}"; do
    if [ -n "$steamcl_mount" ] && [ "$(findmnt -rno TARGET -T "$g" 2>/dev/null || true)" = "$steamcl_mount" ]; then
      SELECTED_GRUB="$g"
      return
    fi
  done

  SELECTED_GRUB="${GRUB_CANDIDATES[0]}"
}

write_cfg_to_custom_dir() {
  local custom_dir="$1"
  local grub_dev="$2"
  local cfg_path="$custom_dir/deck-sb.cfg"
  local kernel_block

  deck_dialog --infobox "Writing SteamOS boot config..." 5 70

  mkdir -p "$custom_dir" || {
    sb_error "Failed to create $custom_dir" 10 80
    exit 1
  }

  if [ ! -f "$DECK_SB_CFG_TEMPLATE" ]; then
    sb_error "Missing deck-sb.cfg template at $DECK_SB_CFG_TEMPLATE" 10 80
    exit 1
  fi

  local partsets_hint_path="/SteamOS/partsets"
  local partsets_dir="" esp_root="" partuuid_a="" partuuid_b="" partsets_source=""
  local partsets_mount=""
  local partsets_display_path="" partsets_display_source=""

  esp_root=$(findmnt -rno TARGET -T "$custom_dir" 2>/dev/null || true)
  if [ -z "$esp_root" ]; then
    esp_root=$(dirname "$(dirname "$custom_dir")")
  fi
  partsets_dir=$(find_partsets_for_custom_dir "$custom_dir")
  if [ -n "$partsets_dir" ]; then
    partsets_source=$(findmnt -rno SOURCE -T "$partsets_dir" 2>/dev/null || true)
    partsets_source=$(clean_source_path "$partsets_source")
    partsets_mount=$(findmnt -rno TARGET -T "$partsets_dir" 2>/dev/null || true)
    if [ -n "$partsets_source" ] && [ -n "$grub_dev" ] && [ "$partsets_source" != "$grub_dev" ]; then
      log_debug "partsets: source $partsets_source != grub_dev $grub_dev (continuing)"
    fi
  fi
  if [ -n "$partsets_dir" ]; then
    if [[ "$partsets_dir" == "$esp_root"* ]]; then
      log_debug "partsets: using esp root match $partsets_dir"
    elif [ -n "${TMP_EFI_MOUNT_BASE:-}" ] && [[ "$partsets_dir" == "$TMP_EFI_MOUNT_BASE"/* ]]; then
      log_debug "partsets: using fallback match $partsets_dir"
    else
      log_debug "partsets: ignoring $partsets_dir (outside esp root and $TMP_EFI_MOUNT_BASE)"
      partsets_dir=""
      partsets_source=""
      partsets_mount=""
    fi
  fi
  if [ -n "$partsets_dir" ] && [ -n "$partsets_mount" ]; then
    if [[ "$partsets_dir" == "$partsets_mount"* ]]; then
      partsets_hint_path="${partsets_dir#$partsets_mount}"
    fi
  fi
  if [ -z "$partsets_hint_path" ]; then
    partsets_hint_path="/SteamOS/partsets"
  fi
  if [[ "$partsets_hint_path" != /* ]]; then
    partsets_hint_path="/$partsets_hint_path"
  fi
  if [ "$partsets_hint_path" != "/" ]; then
    partsets_hint_path="${partsets_hint_path%/}"
  fi
  if [ -z "$partsets_hint_path" ]; then
    partsets_hint_path="/SteamOS/partsets"
  fi
  if [ -n "$partsets_dir" ]; then
    partsets_display_path=$(deck_display_path "$partsets_dir")
  else
    partsets_display_path="(not found)"
  fi
  if [ -n "$partsets_source" ]; then
    partsets_display_source="$partsets_source"
  else
    partsets_display_source="(unknown)"
  fi
  deck_dialog --msgbox "Partsets detection:\n\nDirectory: ${partsets_display_path}\nDevice: ${partsets_display_source}\nGRUB Path: ${partsets_hint_path}" 12 90
  log_debug "esp root: $esp_root"
  if [ -n "$partsets_dir" ]; then
    partuuid_a=$(read_partset_rootfs_partuuid "$partsets_dir/A" 2>/dev/null || true)
    partuuid_b=$(read_partset_rootfs_partuuid "$partsets_dir/B" 2>/dev/null || true)
  fi
  log_debug "rootfs partuuid: A=${partuuid_a:-missing} B=${partuuid_b:-missing}"
  log_debug "partsets path hint: ${partsets_hint_path}"
  log_debug "partsets source: ${partsets_source:-missing}"

  kernel_block=$(cat <<EOF
    echo "DeckSB: root=\$root"
    echo "DeckSB: linux ${STEAMOS_KERNEL_IMAGE} console=tty1 rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.systemd.gpt_auto=no log_buf_len=4M amd_iommu=off amdgpu.lockup_timeout=5000,10000,10000,5000 ttm.pages_min=2097152 amdgpu.sched_hw_submission=4 audit=0 fsck.mode=auto fsck.repair=preen fbcon=rotate:1 ${STEAMOS_KERNEL_VERBOSITY} plymouth.ignore-serial-consoles fbcon=vc:4-6 noresume \$d_ar_r \$d_ar_e \$d_ar_v \$d_ar_h \$d_ar_s"
    echo "DeckSB: initrd ${STEAMOS_INITRD_IMAGES}"
    if [ -n "\$root" ]; then
        if [ -f "(\$root)${STEAMOS_KERNEL_IMAGE}" ]; then
            echo "DeckSB: kernel ok ${STEAMOS_KERNEL_IMAGE}"
        else
            echo "DeckSB: kernel missing ${STEAMOS_KERNEL_IMAGE}"
            ls (\$root)/boot/
        fi
        for deck_initrd in ${STEAMOS_INITRD_IMAGES}; do
            if [ -f "(\$root)\$deck_initrd" ]; then
                echo "DeckSB: initrd ok \$deck_initrd"
            else
                echo "DeckSB: initrd missing \$deck_initrd"
            fi
        done
    else
        echo "DeckSB: root not set"
    fi
    if linux ${STEAMOS_KERNEL_IMAGE} \
        console=tty1 \
        rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 \
        rd.systemd.gpt_auto=no \
        log_buf_len=4M \
        amd_iommu=off \
        amdgpu.lockup_timeout=5000,10000,10000,5000 \
        ttm.pages_min=2097152 \
        amdgpu.sched_hw_submission=4 \
        audit=0 \
        fsck.mode=auto fsck.repair=preen \
        fbcon=rotate:1 \
        ${STEAMOS_KERNEL_VERBOSITY} \
        plymouth.ignore-serial-consoles \
        fbcon=vc:4-6 \
        noresume \
        \$d_ar_r \$d_ar_e \$d_ar_v \$d_ar_h \$d_ar_s; then
        if initrd ${STEAMOS_INITRD_IMAGES}; then
            boot
        else
            echo "DeckSB: initrd load failed. Re-run the EFI installer to refresh SteamOS boot assets."
            sleep 5
        fi
    else
        echo "DeckSB: kernel load failed. The active kernel is unsigned."
        echo "DeckSB: Re-run the EFI installer to sign all SteamOS kernels."
        sleep 5
    fi
EOF
)

  {
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "__DECK_SB_KERNEL_BLOCK__" ]; then
        printf '%s\n' "$kernel_block"
      else
        printf '%s\n' "$line"
      fi
    done < "$DECK_SB_CFG_TEMPLATE"
  } > "$cfg_path" || {
    sb_error "Failed to write $cfg_path" 10 80
    exit 1
  }

  chmod 0644 "$cfg_path" 2>/dev/null || true
}

maybe_update_clover_config() {
  local decksb_dir="$1"
  local efi_root
  local clover_dir=""
  local config_path

  efi_root=$(dirname "$decksb_dir")

  for candidate in \
      "$efi_root/clover" \
      "$efi_root/Clover"; do
    if [ -d "$candidate" ] && [ -f "$candidate/config.plist" ]; then
      clover_dir="$candidate"
      break
    fi
  done

  if [ -z "$clover_dir" ]; then
    return 0
  fi

  config_path="$clover_dir/config.plist"

  if [ ! -f "$CLOVER_ENTRY_TEMPLATE" ]; then
    deck_dialog --msgbox "Clover directory detected at $(deck_display_path "$clover_dir"), but the entry template is missing." 10 80
    return 0
  fi

  if grep -q "SteamOS Jump Loader" "$config_path" 2>/dev/null; then
    return 0
  fi

  deck_dialog --infobox "Adding SteamOS Jump Loader to Clover config..." 5 70
  local tmp_file
  tmp_file=$(mktemp) || {
    sb_error "Failed to create temporary file while editing $(deck_display_path "$config_path")." 10 80
    return 1
  }

  if awk -v tpl="$CLOVER_ENTRY_TEMPLATE" '
BEGIN {
  inserted = 0
  seen_entries_key = 0
}
{
  print $0

  if (!inserted && seen_entries_key && index($0, "<array>") > 0) {
    while ((getline line < tpl) > 0) {
      print line
    }
    close(tpl)
    inserted = 1
    seen_entries_key = 0
  }

  if (!inserted && index($0, "<key>Entries</key>") > 0) {
    seen_entries_key = 1
  }
}
END {
  exit inserted ? 0 : 1
}
' "$config_path" > "$tmp_file"; then
    if mv "$tmp_file" "$config_path"; then
      local clover_message="Clover config found at $(deck_display_path "$config_path").\\nA SteamOS Jump Loader entry was added to the top of its boot menu."

      if grep -q '<key>DefaultLoader</key>' "$config_path" 2>/dev/null; then
        tmp_dloader=$(mktemp)
        if awk '
BEGIN { updated = 0 }
{
  line = $0
  if (!updated && line ~ /<key>[\t ]*DefaultLoader[\t ]*<\/key>/) {
    print line
    if (getline nextline) {
      gsub(/<string>.*<\/string>/, "<string>\\EFI\\deck-sb\\jump.efi</string>", nextline)
      print nextline
      updated = 1
    }
  } else {
    print line
  }
}
END { exit updated ? 0 : 1 }
' "$config_path" > "$tmp_dloader"; then
          if mv "$tmp_dloader" "$config_path"; then
            clover_message+="\\nDefault Clover loader changed to \\EFI\\deck-sb\\jump.efi."
          fi
        else
          rm -f "$tmp_dloader" 2>/dev/null || true
        fi
      fi

      clover_message+="\\n\\nReminder: re-sign Clover's EFI binaries with deck-sign-efi.sh so Secure Boot trusts them."
      deck_dialog --infobox "$clover_message" 12 80
      return 0
    fi
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  sb_error "Failed to update Clover config at $(deck_display_path "$config_path"). Add the SteamOS Jump Loader entry manually." 10 80
  return 1
}

confirm_overwrite() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  deck_dialog --yesno "$(basename "$path") already exists at $(deck_display_path "$path").\nOverwrite it?" 10 70
}

purge_existing_boot_entries() {
  local label="$1"
  local line id
  while IFS= read -r line; do
    case "$line" in
      Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*"$label"*)
        id=${line%% *}
        id=${id#Boot}
        id=${id%\*}
        efibootmgr -b "$id" -B >/dev/null 2>&1 || true
        ;;
    esac
  done < <(efibootmgr 2>/dev/null || true)
}
install_jump_loader() {
  local steamcl_path="$1"
  local grub_path="$2"

  local steamcl_mount steamcl_source
  local grub_source=""
  local custom_dir custom_jump
  local partnum disk output

  steamcl_mount=$(findmnt -rno TARGET -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(findmnt -rno SOURCE -T "$steamcl_path" 2>/dev/null || true)
  steamcl_source=$(clean_source_path "$steamcl_source")

  if [ -z "$steamcl_mount" ] || [ -z "$steamcl_source" ]; then
    sb_error "Unable to determine mountpoint for $steamcl_path." 10 80
    exit 1
  fi

  if [ ! -b "$steamcl_source" ]; then
    sb_error "Backing device $steamcl_source not found." 10 80
    exit 1
  fi

  if [ -n "$grub_path" ]; then
    grub_source=$(findmnt -rno SOURCE -T "$grub_path" 2>/dev/null || true)
    grub_source=$(clean_source_path "$grub_source")
  fi
  if [ -z "$grub_source" ]; then
    grub_source="$steamcl_source"
  fi

  update_kernel_initrd_from_grub "$grub_path" "$steamcl_path"

  if ! ensure_rw_mount "$steamcl_mount"; then
    sb_error "Unable to remount $steamcl_mount writable. Remount it manually and retry." 10 80
    exit 1
  fi

  custom_dir="$steamcl_mount/EFI/deck-sb"
  if ! mkdir -p "$custom_dir"; then
    sb_error "Failed to create $custom_dir" 10 80
    exit 1
  fi
  custom_jump="$custom_dir/$TARGET_FILENAME"
  bootpng="$custom_dir/boot.png"

  if ! confirm_overwrite "$custom_jump"; then
    deck_dialog --infobox "Installation cancelled." 6 60
    return 0
  fi

  if ! output=$(install -m 0644 "$JUMP_SOURCE" "$custom_jump" 2>&1); then
    sb_error "Failed to copy jump loader to $(deck_display_path "$custom_jump").\n\n$output" 12 80
    exit 1
  fi
  if ! output=$(install -m 0644 "$PNG_SOURCE" "$bootpng" 2>&1); then
    sb_error "Failed to copy boot image to $(deck_display_path "$bootpng").\n\n$output" 12 80
    exit 1
  fi
  deck_dialog --msgbox "Copied jump loader to $(deck_display_path "$custom_jump")." 8 80

  write_cfg_to_custom_dir "$custom_dir" "$grub_source"
  maybe_update_clover_config "$custom_dir"

  partnum=$(derive_partnum "$steamcl_source" 2>/dev/null || true)
  disk=$(find_disk_for_part "$steamcl_source" || true)

  if [ -z "$disk" ] || [ -z "$partnum" ]; then
    sb_error "Unable to derive disk metadata for $steamcl_source." 10 80
    exit 1
  fi

  local efi_rel_path="\\EFI\\deck-sb\\$TARGET_FILENAME"

  # remove old entries with the same labels before adding a new one
  local label
  for label in "${BOOT_LABELS[@]}"; do
    purge_existing_boot_entries "$label"
  done

  deck_dialog --infobox "Adding UEFI boot entry..." 5 70
  if ! output=$(efibootmgr -c -d "$disk" -p "$partnum" -l "$efi_rel_path" -L "$NEW_EFI_LABEL" 2>&1); then
    sb_report "UEFI boot entry not updated" "efibootmgr failed:\n$output\n\nThe jump loader was still installed at $(deck_display_path "$custom_jump"). You can add a boot entry manually or use Boot From File." 18 90
    record_jump_state "$custom_jump"
    LAST_INSTALLED_JUMP="$custom_jump"
    return 0
  fi

  deck_dialog --msgbox "Boot entry created:\n$output" 8 80
  record_jump_state "$custom_jump"
  LAST_INSTALLED_JUMP="$custom_jump"
}

find_installed_jump() {
  local keep_mounts="${1:-0}"
  local attempt max_attempts=3
  local cached

  if cached=$(read_jump_state); then
    if [ "$cached" = "none" ]; then
      return 1
    fi
    printf '%s\n' "$cached"
    return 0
  fi

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    # Use dedicated, temporary lists so detection doesn't disturb global mounts.
    local -a _mounts=() _dirs=()
    local -A _added=()
    local -A _skip_iso=()

    collect_iso_device_skip_map "_skip_iso"

    seed_default_search_dirs "_dirs" "_added" "$ISO_MOUNT"
    collect_device_search_dirs "_dirs" "_added" "_mounts" "$ISO_MOUNT" "$TMP_EFI_MOUNT_BASE" "$TMP_LINUX_MOUNT_BASE" "" "_skip_iso"

    local dir found
    for dir in "${_dirs[@]}"; do
      while IFS= read -r -d '' found; do
        record_jump_state "$found"
        printf '%s\n' "$found"
        if [ "$keep_mounts" -eq 1 ]; then
          TEMP_MOUNTS+=("${_mounts[@]}")
        else
          cleanup_mounts _mounts
        fi
        return 0
      done < <(run_find_timeout "$dir" 6 -type f -ipath "*/efi/deck-sb/$TARGET_FILENAME" || true)
    done

    cleanup_mounts _mounts
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep 1
    fi
  done

  record_jump_state ""
  return 1
}

remove_jump_loader() {
  local jump_path="${1:-}"
  [ -n "$jump_path" ] || jump_path=$(find_installed_jump 1 2>/dev/null || true)

  if [ -z "$jump_path" ]; then
    deck_dialog --msgbox "No Deck SB jump loader was found to remove." 8 70
    record_jump_state ""
    return 0
  fi

  local mp; mp=$(findmnt -rno TARGET -T "$jump_path" 2>/dev/null || true)
  if [ -n "$mp" ] && ! ensure_rw_mount "$mp"; then
    sb_error "Cannot obtain write access to $(deck_display_path "$mp")." 9 70
    return 1
  fi

  rm -f "$jump_path" 2>/dev/null || true
  rmdir "$(dirname "$jump_path")" 2>/dev/null || true

  local label
  for label in "${BOOT_LABELS[@]}"; do
    purge_existing_boot_entries "$label"
  done

  deck_dialog --msgbox "Removed Deck SB jump loader and cleared matching UEFI boot entries." 9 80
  record_jump_state ""
  return 0
}

sign_detected_kernels() {
  if ! command -v sbctl >/dev/null 2>&1; then
    deck_dialog --msgbox "sbctl is not available in this environment.\nSkipping kernel signing." 9 80
    return 0
  fi

  deck_dialog --infobox "Scanning for kernels to sign..." 5 70
  collect_kernel_candidates

  if [ "${#KERNEL_CANDIDATES[@]}" -eq 0 ]; then
    deck_dialog --msgbox "No vmlinuz kernels were found to sign." 8 70
    return 0
  fi

  local summary="" success=0 already=0 failed=0
  local kernel display

  for kernel in "${KERNEL_CANDIDATES[@]}"; do
    display=$(deck_display_path "$kernel")
    if ! ERR=$(ensure_rw_for_path "$kernel"); then
      summary+="$display: SKIPPED (read-only)\n${ERR:-Unable to access target.}\n\n"
      failed=$((failed + 1))
      continue
    fi

    deck_dialog --infobox "Signing kernel:\n$display" 6 70
    sbctl_sign_analyze "$kernel"
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
    heading="Kernel signing summary (signed: $success, already: $already)"
  else
    heading="Kernel signing summary (signed: $success, already: $already, failed: $failed)"
  fi

  deck_dialog --msgbox "$(printf '%s\n\n%s' "$heading" "$summary")" 20 90
}

main() {
  if [ ! -f "$JUMP_SOURCE" ]; then
    sb_error "Jump loader $JUMP_SOURCE is missing from the live environment." 10 80
    exit 1
  fi

  scan_devices
  collect_base_candidates
  select_base_candidate

  steamcl_mount_for_pick=$(findmnt -rno TARGET -T "$SELECTED_BASE" 2>/dev/null || true)
  select_grub_for_base "$steamcl_mount_for_pick"

  install_jump_loader "$SELECTED_BASE" "$SELECTED_GRUB"
  if [ -n "$LAST_INSTALLED_JUMP" ]; then
    sign_steamos_kernels_from_partsets "$(dirname "$LAST_INSTALLED_JUMP")"
    sign_detected_kernels
  fi
}

declare -a TEMP_MOUNTS=() SEARCH_DIRS=() BASE_CANDIDATES=() GRUB_CANDIDATES=() KERNEL_CANDIDATES=()
declare -A ADDED_DIRS=() SEEN_BASE=() SEEN_GRUB=() SEEN_KERNELS=()
SELECTED_BASE=""
SELECTED_GRUB=""
LAST_INSTALLED_JUMP=""

trap cleanup EXIT
if [ "${1:-}" = "--detect-installed" ]; then
  if find_installed_jump 0 >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
elif [ "${1:-}" = "--remove" ]; then
  remove_jump_loader
else
  main
fi
