#!/bin/bash
# Common environment values shared across Deck Secure Boot scripts.
: "${DECK_SB_VERSION:=__DECK_SB_VERSION__}"
if [ "$DECK_SB_VERSION" = "__DECK_SB_VERSION__" ]; then
  DECK_SB_VERSION="dev"
fi
: "${DECK_SB_BACKTITLE:=DeckSB Manager v${DECK_SB_VERSION} - D-Pad to navigate, A to select, B to cancel.}"
: "${DECK_SB_KEYDIR:=/usr/share/deck-sb/keys}"
: "${DECK_SB_PENDING_FLAG:=/run/sb_pending_reboot}"
: "${DECK_SB_TARGET_FILENAME:=jump.efi}"
: "${DECK_SB_OLD_EFI_LABEL:=SteamOS (custom jump)}"
: "${DECK_SB_NEW_EFI_LABEL:=Deck SB (Custom Jump)}"
: "${DECK_SB_STATE_DIR:=/run/deck-sb}"
: "${DECK_SB_JUMP_STATE_FILE:=$DECK_SB_STATE_DIR/jump.state}"
: "${DECK_SB_ERROR_FILE:=$DECK_SB_STATE_DIR/last-error}"
: "${DECK_SB_MENU_CONTEXT:=0}"
: "${STEAMOS_ROOT_BASE:=/run/deck-os}"
: "${STEAMOS_BOOT_BASE:=/run/deck-boot}"
# Preferred label for the live ISO; fallback labels keep backward compatibility.
: "${DECK_SB_ISO_LABEL:=DECK_SB}"
: "${DECK_SB_DEBUG_LOG:=/run/deck-sb/install-iso-debug.log}"
: "${DECK_SB_DEBUG:=0}"

if [ "$DECK_SB_VERSION" = "dev" ]; then
  DECK_SB_DEBUG=1
fi

export DECK_SB_BACKTITLE
export DECK_SB_VERSION
export DECK_SB_KEYDIR
export DECK_SB_PENDING_FLAG
export DECK_SB_TARGET_FILENAME
export DECK_SB_OLD_EFI_LABEL
export DECK_SB_NEW_EFI_LABEL
export DECK_SB_STATE_DIR
export DECK_SB_JUMP_STATE_FILE
export DECK_SB_ERROR_FILE
export DECK_SB_MENU_CONTEXT
export STEAMOS_ROOT_BASE
export STEAMOS_BOOT_BASE
export DECK_SB_ISO_LABEL
export DECK_SB_DEBUG_LOG
export DECK_SB_DEBUG

sanitize_printable() {
  LC_ALL=C tr -cd '\11\12\15\40-\176'
}

sbctl_sign_capture() {
  # Run sbctl sign capturing output/status without tripping set -e on failure.
  local target="$1"
  SBCTL_RAW_OUTPUT=""
  SBCTL_STATUS=0

  # Allow callers to short-circuit gracefully if sbctl is missing.
  if ! command -v sbctl >/dev/null 2>&1; then
    SBCTL_STATUS=127
    SBCTL_RAW_OUTPUT="sbctl not found"
    return 0
  fi

  if SBCTL_RAW_OUTPUT=$(sbctl sign -s "$target" 2>&1); then
    SBCTL_STATUS=0
  else
    SBCTL_STATUS=$?
  fi
  return 0
}

secure_boot_enabled() {
  command -v sbctl >/dev/null 2>&1 || return 1
  local sb_line
  sb_line=$(sbctl status 2>/dev/null | grep -i 'Secure Boot' || true)
  if echo "$sb_line" | grep -qi 'enabled'; then
    return 0
  fi
  return 1
}

format_display_path() {
  local path="$1"
  shift || true
  local display="$path"
  local prefix
  for prefix in "$@"; do
    if [[ -n "$prefix" && "$display" == "$prefix"* ]]; then
      display="${display#"$prefix"}"
      display="${display#/}"
    fi
  done
  printf '%s\n' "$display" | sed -e 's://*:/:g'
}

deck_dialog() {
  local backtitle="${BACKTITLE:-$DECK_SB_BACKTITLE}"
  dialog --backtitle "$backtitle" "$@"
}

deck_message_box() {
  # Message box with optional heading/body separation and sizing.
  local heading="$1" body="$2" height="${3:-15}" width="${4:-90}"
  [ -n "$body" ] || body="(no output)"
  deck_dialog --msgbox "$(printf '%s\n\n%s' "$heading" "$body")" "$height" "$width"
}

deck_info_box() {
  local body="$1" height="${2:-6}" width="${3:-70}"
  deck_dialog --infobox "$body" "$height" "$width"
}

sb_error() {
  local msg="$1" height="${2:-10}" width="${3:-80}"
  sb_set_error "$msg"
  if [ "${DECK_SB_MENU_CONTEXT:-0}" -eq 1 ]; then
    return 0
  fi
  deck_dialog --msgbox "$msg" "$height" "$width"
  return 0
}

sb_info() {
  local msg="$1" height="${2:-8}" width="${3:-80}"
  deck_dialog --msgbox "$msg" "$height" "$width"
}

sb_progress() {
  local msg="$1" height="${2:-6}" width="${3:-70}"
  deck_dialog --infobox "$msg" "$height" "$width"
}

sb_log() {
  local msg="$1"
  [ "${DECK_SB_DEBUG:-0}" -eq 1 ] || return 0
  mkdir -p "$(dirname "$DECK_SB_DEBUG_LOG")" 2>/dev/null || true
  printf '%s\n' "$msg" >> "$DECK_SB_DEBUG_LOG"
}

log_debug() {
  sb_log "$1"
}

sb_run_capture() {
  local label="$1"
  shift
  local output status
  output=$("$@" 2>&1)
  status=$?
  if [ "${DECK_SB_DEBUG:-0}" -eq 1 ]; then
    sb_log "cmd=${label} exit=${status}"
    if [ -n "$output" ]; then
      sb_log "$output"
    fi
  fi
  printf '%s' "$output"
  return $status
}

sb_report() {
  local heading="$1" body="$2" height="${3:-18}" width="${4:-90}"
  if [ "${DECK_SB_MENU_CONTEXT:-0}" -eq 1 ]; then
    deck_message_box "$heading" "$body" "$height" "$width"
  else
    printf '%s\n\n%s\n' "$heading" "$body"
  fi
}

sb_clear_error() {
  mkdir -p "$DECK_SB_STATE_DIR" 2>/dev/null || true
  rm -f "$DECK_SB_ERROR_FILE" 2>/dev/null || true
}

sb_set_error() {
  local msg="$1"
  mkdir -p "$DECK_SB_STATE_DIR" 2>/dev/null || true
  [ -n "$msg" ] || msg="Unknown error."
  printf '%s\n' "$msg" > "$DECK_SB_ERROR_FILE"
}

sb_get_error() {
  [ -s "$DECK_SB_ERROR_FILE" ] || return 1
  cat "$DECK_SB_ERROR_FILE"
}

detect_fstype_for_path() {
  local path="$1"
  findmnt -rno FSTYPE -T "$path" 2>/dev/null | tr 'A-Z' 'a-z'
}

is_fat_fstype() {
  local fstype="$1"
  [[ "${fstype,,}" =~ ^(vfat|fat|fat16|fat32)$ ]]
}

mount_opts_has_flag() {
  # Check for a comma-delimited mount option (avoid substring matches like errors=remount-ro).
  local opts="${1// /}" flag="$2"
  [[ -n "$opts" ]] || return 1
  [[ ",$opts," == *",$flag,"* ]]
}

run_find_timeout() {
  # find wrapper with optional timeout support (uses FIND_TIMEOUT/TIMEOUT_BIN if set)
  local dir="$1" maxdepth="$2"
  shift 2
  [ -d "$dir" ] || return
  local cmd=(find "$dir" -maxdepth "$maxdepth" "$@" -print0)
  local tbin="${TIMEOUT_BIN:-}"
  [ -n "$tbin" ] || tbin=$(command -v timeout || true)
  if [ -n "$tbin" ]; then
    "$tbin" "${FIND_TIMEOUT:-15}" "${cmd[@]}" 2>/dev/null
  else
    "${cmd[@]}" 2>/dev/null
  fi
}

add_unique_file() {
  # Append a file path to an array if it exists, is unique, and not under an ISO mount.
  local list_ref="$1" seen_ref="$2" iso_mount="$3" path="$4"
  declare -n _list="$list_ref" _seen="$seen_ref"
  [ -f "$path" ] || return 0
  if [[ -n "$iso_mount" && "$path" == "$iso_mount"* ]]; then
    return 0
  fi
  if [[ -n "${_seen[$path]:-}" ]]; then
    return 0
  fi
  _list+=("$path")
  _seen["$path"]=1
}

add_fat_candidate() {
  # Add a file only if it sits on a FAT filesystem (e.g., ESP).
  local list_ref="$1" seen_ref="$2" iso_mount="$3" path="$4"
  local fstype
  fstype=$(detect_fstype_for_path "$path" 2>/dev/null || true)
  is_fat_fstype "$fstype" && add_unique_file "$list_ref" "$seen_ref" "$iso_mount" "$path"
}

cleanup_mounts() {
  # Given a nameref to an array of mounts, try to unmount and remove them.
  local mounts_ref="$1"
  declare -n _mounts="$mounts_ref"
  local m
  for m in "${_mounts[@]-}"; do
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
}

add_search_dir() {
  local list_ref="$1" seen_ref="$2" dir="$3" iso_mount="${4:-}"
  declare -n _list="$list_ref" _seen="$seen_ref"
  [ -d "$dir" ] || return 0
  if [[ -n "$iso_mount" && "$dir" == "$iso_mount"* ]]; then
    return 0
  fi
  if [[ -n "${_seen[$dir]:-}" ]]; then
    return 0
  fi
  _list+=("$dir")
  _seen["$dir"]=1
}

seed_default_search_dirs() {
  local list_ref="$1" seen_ref="$2" iso_mount="${3:-}"
  local roots=(
    /boot
    /boot/efi
    /efi
    /mnt
    /run/media/*/*
  )
  local root path
  for root in "${roots[@]}"; do
    for path in $root; do
      add_search_dir "$list_ref" "$seen_ref" "$path" "$iso_mount"
    done
  done
}

collect_device_search_dirs() {
  local list_ref="$1" seen_ref="$2" temps_ref="$3" iso_mount="$4"
  local efi_base="$5" linux_base="$6" progress_hook="${7:-}" skip_map_ref="${8:-}"
  declare -n _list="$list_ref" _seen="$seen_ref" _temps="$temps_ref"
  if [ -n "$skip_map_ref" ]; then
    declare -n _skip="$skip_map_ref"
  fi

  local linux_fstypes="${LINUX_FSTYPES:-ext2|ext3|ext4|btrfs|xfs|f2fs}"
  local parttype guid lowerfstype mount_base add_boot_dir target_mount
  local -a guid_list=()
  if [ -n "${LINUX_GPT_GUIDS[*]:-}" ]; then
    guid_list=("${LINUX_GPT_GUIDS[@]}")
  fi

  while read -r dev fstype parttype target_mount; do
    [[ -b "$dev" ]] || continue
    if [ -n "$skip_map_ref" ] && [ -n "${_skip[$dev]:-}" ]; then
      continue
    fi
    # Skip known live media by label or iso9660 to avoid tearing down the install USB.
    local dev_label=""
    dev_label=$(lsblk -nrpo LABEL "$dev" 2>/dev/null | head -n1 || true)
    local iso_label
    for iso_label in "${DECK_SB_ISO_LABEL:-}" "DECK_SB" "DECK SB"; do
      if [ -n "$iso_label" ] && [ "$dev_label" = "$iso_label" ]; then
        continue 2
      fi
    done
    lowerfstype="${fstype,,}"
    if [ "$lowerfstype" = "iso9660" ]; then
      continue
    fi
    parttype="${parttype^^}"
    mount_base=""
    add_boot_dir=0

    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ || "$parttype" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]]; then
      mount_base="$efi_base"
    elif [[ "$lowerfstype" =~ ^($linux_fstypes)$ ]]; then
      mount_base="$linux_base"
      add_boot_dir=1
    else
      for guid in "${guid_list[@]}"; do
        if [[ "$parttype" == "$guid" ]]; then
          mount_base="$linux_base"
          add_boot_dir=1
          break
        fi
      done
    fi

    [ -n "$mount_base" ] || continue

    if [ -z "$target_mount" ] || [ "$target_mount" = "-" ]; then
      local existing_mount
      existing_mount=$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -n1 || true)
      if [ -n "$existing_mount" ] && [ "$existing_mount" != "-" ]; then
        target_mount="$existing_mount"
      fi
    fi

    if [ -z "$target_mount" ] || [ "$target_mount" = "-" ]; then
      target_mount="$mount_base/$(basename "$dev")"
      mkdir -p "$target_mount"
      if mount -o ro "$dev" "$target_mount"; then
        _temps+=("$target_mount")
      else
        rmdir "$target_mount"
        continue
      fi
    fi

    if [ "$mount_base" = "$efi_base" ]; then
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/EFI" "$iso_mount"
      if [ -n "$progress_hook" ] && [ "$(type -t "$progress_hook" 2>/dev/null)" = "function" ]; then
        "$progress_hook" "Mounted EFI $(basename "$dev")"
      fi
    elif [ "$add_boot_dir" -eq 1 ]; then
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/boot" "$iso_mount"
      add_search_dir "$list_ref" "$seen_ref" "$target_mount/boot/EFI" "$iso_mount"
      if [ -n "$progress_hook" ] && [ "$(type -t "$progress_hook" 2>/dev/null)" = "function" ]; then
        "$progress_hook" "Mounted Linux $(basename "$dev")"
      fi
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
}

collect_iso_device_skip_map() {
  # Populate an associative array keyed by device paths that should be ignored
  # (e.g., the live ISO device) to avoid being mounted/unmounted during scans.
  local dest_ref="$1"
  if ! declare -p "$dest_ref" 2>/dev/null | grep -q 'declare \-A'; then
    eval "declare -gA $dest_ref=()"
  fi
  declare -n _skip="$dest_ref"
  _skip=()

  local iso_paths=(
    /run/archiso/bootmnt
    /run/initramfs/archiso/bootmnt
  )
  if [ -n "${DECK_SB_ISO_ROOT:-}" ]; then
    iso_paths+=("$DECK_SB_ISO_ROOT")
  fi

  local path src
  for path in "${iso_paths[@]}"; do
    [ -n "$path" ] || continue
    src=$(findmnt -rno SOURCE --target "$path" 2>/dev/null || true)
    src=${src%%[*}
    if [ -n "$src" ]; then
      _skip["$src"]=1
      local resolved
      resolved=$(readlink -f "$src" 2>/dev/null || true)
      [ -n "$resolved" ] && _skip["$resolved"]=1
    fi
  done

  local labels=("$DECK_SB_ISO_LABEL" "DECK_SB" "DECK SB")
  local line dev label candidate
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    [ -n "$dev" ] || continue
    for candidate in "${labels[@]}"; do
      [ -n "$candidate" ] || continue
      if [ "$label" = "$candidate" ]; then
        _skip["$dev"]=1
        local resolved
        resolved=$(readlink -f "$dev" 2>/dev/null || true)
        [ -n "$resolved" ] && _skip["$resolved"]=1
      fi
    done
  done < <(lsblk -rpno NAME,LABEL -P 2>/dev/null || true)
}

locate_steamos_root_within() {
  local base="$1" fstype="$2" candidate

  local guesses=(
    '@rootfs'
    '@rootfs.ro'
    'rootfs'
    'rootfs.ro'
    'steamroot'
    'steamrootfs'
  )

  local rel
  for rel in "${guesses[@]}"; do
    candidate="$base/$rel"
    if is_steamos_tree "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [ "$fstype" = "btrfs" ] && command -v find >/dev/null 2>&1; then
    local match etc_dir root_dir
    match=$(find "$base" -maxdepth 5 -path '*/etc/os-release' -print -quit 2>/dev/null || true)
    if [ -n "$match" ]; then
      etc_dir=$(dirname "$match")
      root_dir=$(dirname "$etc_dir")
      printf '%s\n' "$root_dir"
      return 0
    fi
  fi

  if is_steamos_tree "$base"; then
    printf '%s\n' "$base"
    return 0
  fi

  return 1
}

find_grub_cfg_for_paths() {
  local attempt path dir candidate
  for attempt in "$1" "$2"; do
    path="$attempt"
    [ -n "$path" ] || continue
    dir=$(dirname "$path" 2>/dev/null || true)
    [ -n "$dir" ] || continue
    candidate="$dir/grub.cfg"
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$(find "$dir" -maxdepth 2 -path '*/steamos/grub.cfg' -print -quit 2>/dev/null || true)
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_steamos_root_path() {
  local mount_base="${1:-/run/deck-os}" temps_ref="${2:-TEMP_MOUNTS}" locator_fn="${3:-locate_steamos_root_within}"
  declare -n _temps="$temps_ref"

  local linux_fstypes="${LINUX_FSTYPES:-ext2|ext3|ext4|btrfs|xfs|f2fs}"
  local -a guid_list=()
  if [ -n "${LINUX_GPT_GUIDS[*]:-}" ]; then
    guid_list=("${LINUX_GPT_GUIDS[@]}")
  fi

  local partmp mounted_here lowerfstype parttype candidate guid
  while read -r dev fstype parttype partmnt; do
    [[ -b "$dev" ]] || continue
    lowerfstype="${fstype,,}"
    parttype="${parttype^^}"

    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
      continue
    fi

    if [[ ! "$lowerfstype" =~ ^($linux_fstypes)$ ]]; then
      guid=""
      for guid in "${guid_list[@]}"; do
        if [[ "$parttype" == "$guid" ]]; then
          break
        fi
        guid=""
      done
      [ -n "$guid" ] || continue
    fi

    partmp="$partmnt"
    mounted_here=0
    if [ -z "$partmp" ] || [ "$partmp" = "-" ]; then
      partmp="$mount_base/$(basename "$dev")"
      mkdir -p "$partmp"
      if mount "$dev" "$partmp"; then
        _temps+=("$partmp")
        mounted_here=1
      else
        rmdir "$partmp"
        continue
      fi
    fi

    candidate=""
    if [ -n "$locator_fn" ] && [ "$(type -t "$locator_fn" 2>/dev/null)" = "function" ]; then
      candidate="$($locator_fn "$partmp" "$lowerfstype" 2>/dev/null || true)"
    fi
    if [ -z "$candidate" ] && is_steamos_tree "$partmp"; then
      candidate="$partmp"
    fi

    if [ -n "$candidate" ] && is_steamos_tree "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi

    if [ "$mounted_here" -eq 1 ]; then
      umount "$partmp" 2>/dev/null || true
      rmdir "$partmp" 2>/dev/null || true
      local last_index=$(( ${#_temps[@]} - 1 ))
      unset "_temps[$last_index]"
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
  return 1
}

is_steamos_tree() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  [ -f "$dir/etc/os-release" ] || return 1
  return 0
}

ensure_rw_mount() {
  local mp="$1"
  local src opts fstype
  src=$(findmnt -nro SOURCE --target "$mp" 2>/dev/null || true)
  opts=$(findmnt -nro OPTIONS --target "$mp" 2>/dev/null || true)
  opts="${opts// /}"
  fstype=$(findmnt -nr -T "$mp" -o FSTYPE 2>/dev/null || true)
  if [ -z "$opts" ]; then
    return 0
  fi
  if mount_opts_has_flag "$opts" "ro"; then
    mount -o remount,rw "$mp" 2>/dev/null || true
    if [ -n "$src" ]; then
      mount -o remount,rw "$src" "$mp" 2>/dev/null || true
    fi
    opts=$(findmnt -nro OPTIONS --target "$mp" 2>/dev/null || true)
    opts="${opts// /}"
    if mount_opts_has_flag "$opts" "ro" && [ -n "$src" ] && [ -b "$src" ] && [[ "${fstype,,}" != "iso9660" ]]; then
      umount "$mp" 2>/dev/null || true
      mount -o rw "$src" "$mp" 2>/dev/null || true
    fi
    opts=$(findmnt -nro OPTIONS --target "$mp" 2>/dev/null || true)
    opts="${opts// /}"
    mount_opts_has_flag "$opts" "ro" && return 1
  fi
  return 0
}

ensure_rw_for_path() {
  # Best-effort remount of the filesystem containing a given file/dir.
  local target="$1"
  local mp opts
  mp=$(findmnt -rno TARGET -T "$target" 2>/dev/null || true)
  opts=$(findmnt -rno OPTIONS -T "$target" 2>/dev/null || true)
  opts="${opts// /}"
  [ -n "$mp" ] || return 0

  if mount_opts_has_flag "$opts" "ro"; then
    if ensure_rw_mount "$mp"; then
      return 0
    fi
    printf 'Filesystem %s is mounted read-only. Remount it writable and try again.\n' "$mp"
    return 1
  fi

  return 0
}

find_disk_for_part() {
  local part="$1"
  local disk
  disk=$(lsblk -nrpo PKNAME "$part" 2>/dev/null | head -n1 || true)
  if [ -n "$disk" ]; then
    [[ "$disk" == /dev/* ]] || disk="/dev/$disk"
    printf '%s' "$disk"
    return 0
  fi
  if [[ "$part" =~ ^(/dev/[[:alnum:]]+)(p[0-9]+|[0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

derive_partnum() {
  # regex-only partition number extractor
  local part="$1"
  if [[ "$part" =~ ^/dev/[[:alnum:]]+p([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$part" =~ ^/dev/[[:alnum:]]*([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

prepare_steamos_root_for_write() {
  local rootmp="$1"
  local fstype

  if ensure_rw_mount "$rootmp"; then
    return 0
  fi

  fstype=$(findmnt -nr -T "$rootmp" -o FSTYPE 2>/dev/null || true)

  if [ "$fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
    if btrfs property get -ts "$rootmp" ro >/dev/null 2>&1; then
      btrfs property set -ts "$rootmp" ro false >/dev/null 2>&1 || true
      if ensure_rw_mount "$rootmp"; then
        return 0
      fi
    fi
  fi

  if [ -x "$rootmp/usr/bin/steamos-readonly" ]; then
    chroot "$rootmp" /usr/bin/steamos-readonly disable 2>/dev/null || true
    if ensure_rw_mount "$rootmp"; then
      return 0
    fi
  fi

  return 1
}

cleanup_temp_iso_mount() {
  local m preserve="${DECK_SB_ISO_ROOT:-}"
  local labels=("${ISO_VOLUME_LABEL:-}" "DECK_SB" "DECK SB")
  for m in "${ISO_TEMP_MOUNTS[@]-}"; do
    if [ -n "$preserve" ] && [ "$m" = "$preserve" ]; then
      log_debug "cleanup_temp_iso_mount: preserving ISO mount at $m"
      continue
    fi
    local src fstype label keep_live=0
    src=$(findmnt -rno SOURCE --target "$m" 2>/dev/null || true)
    src=${src%%[*}
    if [ -n "$src" ]; then
      fstype=$(lsblk -nrpo FSTYPE "$src" 2>/dev/null | head -n1 || true)
      label=$(lsblk -nrpo LABEL "$src" 2>/dev/null | head -n1 || true)
      [[ "${fstype,,}" = "iso9660" ]] && keep_live=1
      local iso_label
      for iso_label in "${labels[@]}"; do
        [ -n "$iso_label" ] && [ "$label" = "$iso_label" ] && keep_live=1
      done
    fi
    if [ "$keep_live" -eq 1 ]; then
      log_debug "cleanup_temp_iso_mount: keeping live media mount at $m (src=${src:-unknown})"
      continue
    fi
    umount "$m" 2>/dev/null || true
    rmdir "$m" 2>/dev/null || true
  done
  ISO_TEMP_MOUNTS=()
  TEMP_ISO_MOUNT=""
}

block_inventory() {
  # Emit NAME/FSTYPE/LABEL/MOUNTPOINT lines in lsblk -P style, preferring blkid.
  local out=""
  if command -v blkid >/dev/null 2>&1; then
    out=$(blkid -o list -w /dev/null 2>/dev/null | awk '
      NR==1 {next} # header
      {
        dev=$1; fstype=$2; label=$3
        $1=""; $2=""; $3=""
        sub(/^[ \t]+/, "", $0)
        mount=$0
        if (mount == "(not mounted)" || mount == "-" ) { mount="" }
        printf "NAME=\"%s\" FSTYPE=\"%s\" LABEL=\"%s\" MOUNTPOINT=\"%s\"\n", dev, fstype, label, mount
      }
    ' ) || true
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT -P 2>/dev/null || lsblk -rpno NAME,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || true
}

collect_iso_roots() {
  local roots=()
  local candidate
  local override="${DECK_SB_ISO_ROOT:-}"
  declare -A seen=()
  log_debug "collect_iso_roots: start (override=$override)"
  for candidate in /run/archiso/bootmnt /run/initramfs/archiso/bootmnt; do
    if [ -d "$candidate" ]; then
      if [ -z "${seen[$candidate]:-}" ]; then
        roots+=("$candidate")
        seen["$candidate"]=1
        log_debug "collect_iso_roots: add default candidate $candidate"
      fi
    fi
  done
  if [ -n "$override" ] && [ -d "$override" ] && [ -z "${seen[$override]:-}" ]; then
    roots+=("$override")
    seen["$override"]=1
    log_debug "collect_iso_roots: add override $override"
  fi
  local labels=("${ISO_VOLUME_LABEL:-}" "DECK_SB" "DECK SB")
  local line dev fstype mnt label
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    local is_live=0
    [[ "${fstype,,}" = "iso9660" ]] && is_live=1
    local candidate_label
    for candidate_label in "${labels[@]}"; do
      [ -n "$candidate_label" ] && [ "$label" = "$candidate_label" ] && is_live=1
    done
    [ "$is_live" -eq 1 ] || continue

    if [ -n "$mnt" ] && [ "$mnt" != "-" ] && [ -d "$mnt" ]; then
      if [ -z "${seen[$mnt]:-}" ]; then
        roots+=("$mnt")
        seen["$mnt"]=1
        log_debug "collect_iso_roots: add mounted $dev at $mnt"
      fi
      continue
    fi

    local tmp
    tmp=$(mktemp -d /run/deck-sb-iso.XXXXXX)
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
      ISO_TEMP_MOUNTS+=("$tmp")
      TEMP_ISO_MOUNT="$tmp"
      roots+=("$tmp")
      seen["$tmp"]=1
      log_debug "collect_iso_roots: mounted $dev at $tmp"
    else
      log_debug "collect_iso_roots: failed to mount $dev at $tmp"
      rmdir "$tmp" 2>/dev/null || true
    fi
  done < <(block_inventory)

  if [ "${#roots[@]}" -eq 0 ]; then
    local mounted
    mounted=$(mount_live_iso_device 2>/dev/null || true)
    if [ -n "$mounted" ]; then
      if [ -z "${seen[$mounted]:-}" ]; then
        roots+=("$mounted")
        seen["$mounted"]=1
      fi
      log_debug "collect_iso_roots: mount_live_iso_device returned $mounted"
    fi
  fi
  if [ "${#roots[@]}" -eq 0 ]; then
    log_debug "collect_iso_roots: none found"
    return 1
  fi
  printf '%s\n' "${roots[@]}"
  log_debug "collect_iso_roots: final roots=${roots[*]}"
  return 0
}

find_live_usb_device() {
  local labels=("${ISO_VOLUME_LABEL:-}" "DECK_SB" "DECK SB")
  local line dev label candidate
  log_debug "find_live_usb_device: searching labels ${labels[*]}"
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    for candidate in "${labels[@]}"; do
      [ -n "$candidate" ] || continue
      if [ "$label" = "$candidate" ]; then
        log_debug "find_live_usb_device: match $dev label=$label"
        echo "$dev"
        return 0
      fi
    done
  done < <(block_inventory)
  return 1
}

find_iso9660_device() {
  local line dev fstype mnt
  log_debug "find_iso9660_device: scanning for iso9660"
  while IFS= read -r line; do
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    [[ "${fstype,,}" = "iso9660" ]] || continue
    log_debug "find_iso9660_device: found $dev mnt=${mnt:--}"
    if [ -n "$mnt" ] && [ "$mnt" != "-" ]; then
      printf '%s|%s\n' "$dev" "$mnt"
    else
      printf '%s|\n' "$dev"
    fi
    return 0
  done < <(block_inventory)
  return 1
}

mount_live_iso_device() {
  if [ -n "$TEMP_ISO_MOUNT" ] && [ -d "$TEMP_ISO_MOUNT" ]; then
    if findmnt -rno SOURCE --target "$TEMP_ISO_MOUNT" >/dev/null 2>&1; then
      log_debug "mount_live_iso_device: reusing TEMP_ISO_MOUNT=$TEMP_ISO_MOUNT"
      echo "$TEMP_ISO_MOUNT"
      return 0
    fi
    rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
    TEMP_ISO_MOUNT=""
  fi
  local dev
  local pre_mounted=""
  dev=$(find_live_usb_device 2>/dev/null || true)
  if [ -z "$dev" ]; then
    local iso_line
    iso_line=$(find_iso9660_device 2>/dev/null || true)
    if [ -n "$iso_line" ]; then
      dev=${iso_line%%|*}
      pre_mounted=${iso_line#*|}
      [ "$pre_mounted" = "$iso_line" ] && pre_mounted=""
    fi
  fi
  if [ -z "$dev" ]; then
    log_debug "mount_live_iso_device: no device found"
    return 1
  fi
  if [ -n "$pre_mounted" ] && [ -d "$pre_mounted" ]; then
    log_debug "mount_live_iso_device: using pre-mounted $pre_mounted for $dev"
    echo "$pre_mounted"
    return 0
  fi
  local existing
  existing=$(findmnt -rno TARGET -S "$dev" 2>/dev/null || true)
  if [ -n "$existing" ] && [ -d "$existing" ]; then
    log_debug "mount_live_iso_device: using existing mount $existing for $dev"
    echo "$existing"
    return 0
  fi
  TEMP_ISO_MOUNT=$(mktemp -d /run/deck-sb-iso.XXXXXX)
  if mount -o ro "$dev" "$TEMP_ISO_MOUNT" 2>/dev/null; then
    ISO_TEMP_MOUNTS+=("$TEMP_ISO_MOUNT")
    log_debug "mount_live_iso_device: mounted $dev at $TEMP_ISO_MOUNT"
    echo "$TEMP_ISO_MOUNT"
    return 0
  fi
  log_debug "mount_live_iso_device: failed to mount $dev"
  rmdir "$TEMP_ISO_MOUNT" 2>/dev/null || true
  TEMP_ISO_MOUNT=""
  return 1
}

find_kernel_source() {
  local path
  local candidates=(
    /boot/vmlinuz-linux
    /run/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux
    /run/archiso/bootmnt/arch/boot/vmlinuz-linux
    /run/initramfs/archiso/bootmnt/arch/boot/x86_64/vmlinuz-linux
  )
  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/boot/x86_64/vmlinuz-linux"
      "$path/$ISO_INSTALL_DIR/boot/vmlinuz-linux"
      "$path/$ISO_INSTALL_DIR/vmlinuz-linux"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
    iso_path=$(find "$path" -maxdepth 5 -type f -name 'vmlinuz-linux' -print -quit 2>/dev/null || true)
    if [ -n "$iso_path" ]; then
      echo "$iso_path"
      return 0
    fi
  done
  return 1
}

find_initrd_source() {
  local path
  local candidates=(
    /boot/initramfs-linux.img
    /run/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img
    /run/initramfs/archiso/bootmnt/arch/boot/x86_64/initramfs-linux.img
  )
  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/boot/x86_64/initramfs-linux.img"
      "$path/$ISO_INSTALL_DIR/boot/initramfs-linux.img"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
    iso_path=$(find "$path" -maxdepth 5 -type f -name 'initramfs-linux.img' -print -quit 2>/dev/null || true)
    if [ -n "$iso_path" ]; then
      echo "$iso_path"
      return 0
    fi
  done
  return 1
}

find_squashfs_source() {
  local candidates=(
    /run/archiso/airootfs.sfs
    /run/archiso/bootmnt/arch/x86_64/airootfs.sfs
    /run/archiso/bootmnt/airootfs.sfs
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  local path
  local iso_roots=()
  while IFS= read -r path; do
    [ -n "$path" ] && iso_roots+=("$path")
  done < <(collect_iso_roots 2>/dev/null || true)
  for path in "${iso_roots[@]}"; do
    local iso_candidates=(
      "$path/$ISO_INSTALL_DIR/x86_64/airootfs.sfs"
      "$path/$ISO_INSTALL_DIR/airootfs.sfs"
      "$path/airootfs.sfs"
    )
    local iso_path
    for iso_path in "${iso_candidates[@]}"; do
      if [ -f "$iso_path" ]; then
        echo "$iso_path"
        return 0
      fi
    done
  done
  return 1
}

select_iso_files_from_root() {
  # Try to resolve kernel/initrd/squashfs under a given ISO root.
  local root="$1"
  local -n _k="$2" _i="$3" _s="$4"
  local k i s
  k=""; i=""; s=""
  [ -n "$root" ] && [ -d "$root" ] || return 1

  local k_candidates=(
    "$root/$ISO_INSTALL_DIR/boot/x86_64/vmlinuz-linux"
    "$root/$ISO_INSTALL_DIR/boot/vmlinuz-linux"
    "$root/$ISO_INSTALL_DIR/vmlinuz-linux"
  )
  local i_candidates=(
    "$root/$ISO_INSTALL_DIR/boot/x86_64/initramfs-linux.img"
    "$root/$ISO_INSTALL_DIR/boot/initramfs-linux.img"
  )
  local s_candidates=(
    "$root/$ISO_INSTALL_DIR/x86_64/airootfs.sfs"
    "$root/$ISO_INSTALL_DIR/airootfs.sfs"
    "$root/airootfs.sfs"
  )

  for k in "${k_candidates[@]}"; do
    [ -f "$k" ] && break || k=""
  done
  for i in "${i_candidates[@]}"; do
    [ -f "$i" ] && break || i=""
  done
  for s in "${s_candidates[@]}"; do
    [ -f "$s" ] && break || s=""
  done

  if [ -n "$k" ] && [ -n "$i" ] && [ -n "$s" ]; then
    _k="$k"
    _i="$i"
    _s="$s"
    log_debug "select_iso_files_from_root: success root=$root k=$k i=$i s=$s"
    return 0
  fi
  log_debug "select_iso_files_from_root: missing in $root k=${k:-none} i=${i:-none} s=${s:-none}"
  return 1
}

find_iso_payload_sources() {
  local -n _k="$1" _i="$2" _s="$3"
  _k=""; _i=""; _s=""

  local -a roots=() temp_mounts=()
  local -A seen=()

  while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    if [ -z "${seen[$r]:-}" ]; then
      roots+=("$r")
      seen["$r"]=1
      log_debug "find_iso_payload_sources: add root $r (collect_iso_roots)"
    fi
  done < <(collect_iso_roots 2>/dev/null || true)

  while IFS= read -r line; do
    local dev fstype mnt label is_live=0
    dev=${line#NAME=\"}; dev=${dev%%\"*}
    fstype=${line#*FSTYPE=\"}; fstype=${fstype%%\"*}
    label=${line#*LABEL=\"}; label=${label%%\"*}
    mnt=${line#*MOUNTPOINT=\"}; mnt=${mnt%%\"*}
    [[ "${fstype,,}" = "iso9660" ]] && is_live=1
    local iso_label
    for iso_label in "${ISO_VOLUME_LABEL:-}" "DECK_SB" "DECK SB"; do
      [ -n "$iso_label" ] && [ "$label" = "$iso_label" ] && is_live=1
    done
    [ "$is_live" -eq 1 ] || continue

    local root_path="$mnt"
    if [ -z "$root_path" ] || [ "$root_path" = "-" ]; then
      root_path=$(mktemp -d /run/deck-sb-iso.XXXXXX)
      if mount -o ro "$dev" "$root_path" 2>/dev/null; then
        temp_mounts+=("$root_path")
        ISO_TEMP_MOUNTS+=("$root_path")
        TEMP_ISO_MOUNT="$root_path"
        log_debug "find_iso_payload_sources: mounted iso9660 $dev at $root_path"
      else
        log_debug "find_iso_payload_sources: failed to mount iso9660 $dev at $root_path"
        rmdir "$root_path" 2>/dev/null || true
        continue
      fi
    fi

    if [ -n "${seen[$root_path]:-}" ]; then
      log_debug "find_iso_payload_sources: skip duplicate root $root_path"
      continue
    fi
    roots+=("$root_path")
    seen["$root_path"]=1
    log_debug "find_iso_payload_sources: add root $root_path (iso9660 dev=$dev)"
  done < <(block_inventory)

  local r
  for r in "${roots[@]}"; do
    if select_iso_files_from_root "$r" _k _i _s; then
      DECK_SB_ISO_ROOT="$r"
      log_debug "find_iso_payload_sources: found payload under $r"
      return 0
    fi
  done
  log_debug "find_iso_payload_sources: no payload found across roots=${roots[*]}"

  return 1
}

find_steamos_root() {
  local partmp mounted_here
  while read -r dev fstype parttype mnt; do
    [[ -b "$dev" ]] || continue
    local lowerfstype="${fstype,,}"
    if [[ "$lowerfstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
      continue
    fi
    if [[ "$lowerfstype" =~ ^(ext4|btrfs|xfs|f2fs)$ ]]; then
      partmp="$mnt"
      mounted_here=0
      if [ -z "$partmp" ] || [ "$partmp" = "-" ]; then
        partmp="/run/deck-os/$(basename "$dev")"
        mkdir -p "$partmp"
        if mount "$dev" "$partmp"; then
          mounted_here=1
        else
          rmdir "$partmp"
          continue
        fi
      fi
      if is_steamos_tree "$partmp"; then
        echo "$partmp"
        return 0
      fi
      if [ "$mounted_here" -eq 1 ]; then
        umount "$partmp" 2>/dev/null || true
        rmdir "$partmp" 2>/dev/null || true
      fi
    fi
  done < <(lsblk -rpno NAME,FSTYPE,PARTTYPE,MOUNTPOINT)
  return 1
}
