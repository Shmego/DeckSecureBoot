#!/usr/bin/env bash
set -euo pipefail

# set FORCE_REBUILD=1 ./makeefi.sh to force a clean rebuild
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KEY_DIR="${SCRIPT_DIR}/keys"
PK_KEY="${KEY_DIR}/PK.key"
PK_CRT="${KEY_DIR}/PK.pem"

OUT_DIR="${SCRIPT_DIR}/dist"
OUT_EFI="${OUT_DIR}/steamos-jump.signed.efi"

# pin to the working grub
GRUB_COMMIT="2bc0929a2fffbb60995605db6ce46aa3f979a7d2"

BUILD_ROOT="$(pwd)/build-grub"
GRUB_SRC="${BUILD_ROOT}/grub"
GRUB_PREFIX="${BUILD_ROOT}/out"
GRUB_MK="${GRUB_PREFIX}/bin/grub-mkstandalone"
DECKSB_GRUB_CMD_SRC="${SCRIPT_DIR}/grub-decksb-conf.c"
DECKSB_GRUB_CMD_DST_REL="grub-core/commands/decksb_conf.c"
DECKSB_GRUB_CMD_DST="${GRUB_SRC}/${DECKSB_GRUB_CMD_DST_REL}"
DECKSB_GRUB_MOD="${GRUB_PREFIX}/lib/grub/x86_64-efi/decksb_conf.mod"
REBUILD_GRUB=0

install_build_deps() {
  pacman -Sy
  pacman -S --needed --noconfirm \
    git python \
    autoconf automake pkgconf \
    gettext texinfo help2man \
    flex bison libtool patch \
    make gcc \
    sbsigntools
}

# --- preflight ---
[[ -f "$PK_KEY" ]] || { echo "ERROR: $PK_KEY missing"; exit 1; }
[[ -f "$PK_CRT" ]] || { echo "ERROR: $PK_CRT missing"; exit 1; }

install_build_deps
mkdir -p "$OUT_DIR"

if [[ "$FORCE_REBUILD" == "1" ]]; then
  echo "[*] FORCE_REBUILD=1 -> removing $BUILD_ROOT"
  rm -rf "$BUILD_ROOT"
  REBUILD_GRUB=1
fi
mkdir -p "$BUILD_ROOT"

# --- fetch grub ---
if [[ ! -d "$GRUB_SRC" ]]; then
  echo "[*] cloning GRUB ..."
  git clone https://git.savannah.gnu.org/git/grub.git "$GRUB_SRC"
fi

cd "$GRUB_SRC"
echo "[*] checking out GRUB commit $GRUB_COMMIT ..."
git fetch origin
git checkout --force "$GRUB_COMMIT"

if [ -f "$DECKSB_GRUB_CMD_SRC" ]; then
  if [ ! -f "$DECKSB_GRUB_CMD_DST" ] || ! cmp -s "$DECKSB_GRUB_CMD_SRC" "$DECKSB_GRUB_CMD_DST"; then
    echo "[*] updating decksb_conf module source ..."
    cp "$DECKSB_GRUB_CMD_SRC" "$DECKSB_GRUB_CMD_DST"
    REBUILD_GRUB=1
  else
    echo "[*] decksb_conf module source unchanged"
  fi
  if ! grep -q "name = decksb_conf" "$GRUB_SRC/grub-core/Makefile.core.def"; then
    cat >> "$GRUB_SRC/grub-core/Makefile.core.def" <<'EOF'

module = {
  name = decksb_conf;
  common = commands/decksb_conf.c;
};
EOF
    REBUILD_GRUB=1
  fi
fi

if [ ! -f "$DECKSB_GRUB_MOD" ]; then
  REBUILD_GRUB=1
elif command -v strings >/dev/null 2>&1; then
  # Ensure the already-built module exports our latest parser command.
  if ! strings "$DECKSB_GRUB_MOD" | grep -q "d_ps_ok"; then
    echo "[*] decksb_conf.mod is stale (missing d_ps_ok), rebuilding ..."
    REBUILD_GRUB=1
  fi
fi

# --- build grub if needed ---
if [[ ! -x "$GRUB_MK" || "$REBUILD_GRUB" == "1" ]]; then
  echo "[*] patching shim fallback ..."
  sed -i 's/return grub_error (GRUB_ERR_ACCESS_DENIED, N_("shim protocols not found"));/return GRUB_ERR_NONE;/' \
    grub-core/kern/efi/sb.c

  echo "[*] bootstrap ..."
  ./bootstrap

  echo "[*] configure ..."
  ./configure \
    --with-platform=efi \
    --target=x86_64 \
    --prefix="$GRUB_PREFIX"

  echo "[*] make ..."
  make -j"$(nproc)"

  echo "[*] make install ..."
  make install
else
  echo "[*] grub already built, skipping (use FORCE_REBUILD=1 to rebuild)"
fi

cd - >/dev/null

# --- build the tiny builtin config ---
CFG_FILE="$(mktemp)"
EFI_RAW="$(mktemp)"

cat > "$CFG_FILE" <<'EOF'
set default=0
set timeout=3
set deck_sb_cfg_loaded=0

# 1) best case: our config is right beside us
if [ -n "$cmdpath" ]; then
    set mydir="$cmdpath"
    if [ -f $mydir/deck-sb.cfg ]; then
        source $mydir/deck-sb.cfg
        set deck_sb_cfg_loaded=1
    fi

    if [ "$deck_sb_cfg_loaded" = 0 ]; then
        # sometimes cmdpath is just (hd0)/EFI/deck-sb
        insmod regexp
        regexp --set=1:disk '^\(([^,)]+)\)/' "$cmdpath"
        if [ -n "$disk" ]; then
            for p in 1 2 3 4 5 6 7 8; do
                if [ -f ($disk,gpt$p)/EFI/deck-sb/deck-sb.cfg ]; then
                    source ($disk,gpt$p)/EFI/deck-sb/deck-sb.cfg
                    set deck_sb_cfg_loaded=1
                elif [ -f ($disk,gpt$p)/efi/deck-sb/deck-sb.cfg ]; then
                    source ($disk,gpt$p)/efi/deck-sb/deck-sb.cfg
                    set deck_sb_cfg_loaded=1
                elif [ -f ($disk,msdos$p)/EFI/deck-sb/deck-sb.cfg ]; then
                    source ($disk,msdos$p)/EFI/deck-sb/deck-sb.cfg
                    set deck_sb_cfg_loaded=1
                elif [ -f ($disk,msdos$p)/efi/deck-sb/deck-sb.cfg ]; then
                    source ($disk,msdos$p)/efi/deck-sb/deck-sb.cfg
                    set deck_sb_cfg_loaded=1
                fi

                if [ "$deck_sb_cfg_loaded" = 1 ]; then
                    break
                fi
            done
        fi
    fi
fi

# 2) fallback: search lowercase
if [ "$deck_sb_cfg_loaded" = 0 ]; then
    search --file /efi/deck-sb/deck-sb.cfg --set=esp
    if [ -n "$esp" ]; then
        source ($esp)/efi/deck-sb/deck-sb.cfg
        set deck_sb_cfg_loaded=1
    fi
fi

# 3) fallback: search uppercase
if [ "$deck_sb_cfg_loaded" = 0 ]; then
    search --file /EFI/deck-sb/deck-sb.cfg --set=esp
    if [ -n "$esp" ]; then
        source ($esp)/EFI/deck-sb/deck-sb.cfg
        set deck_sb_cfg_loaded=1
    fi
fi

if [ "$deck_sb_cfg_loaded" = 0 ]; then
    menuentry 'Deck SB loader (no config found)' {
        echo 'No deck-sb.cfg found beside this loader or on the ESP.'
        echo 'Make sure your installer wrote /EFI/deck-sb/deck-sb.cfg.'
        sleep 5
    }
fi
EOF

echo "[*] building standalone GRUB EFI ..."
"$GRUB_MK" \
  -O x86_64-efi \
  -o "$EFI_RAW" \
  --modules="part_gpt part_msdos fat ext2 search search_fs_file normal efi_gop efi_uga regexp gfxterm all_video decksb_conf" \
  "boot/grub/unicode.pf2=$(pwd)/unicode.pf2" \
  "boot/grub/grub.cfg=${CFG_FILE}"

echo "[*] signing EFI ..."
sbsign \
  --key "$PK_KEY" \
  --cert "$PK_CRT" \
  --output "$OUT_EFI" \
  "$EFI_RAW"

rm -f "$CFG_FILE" "$EFI_RAW"

echo
echo "[+] built and signed: $OUT_EFI"
echo "Deploy on Deck:"
echo "  sudo mount /dev/nvme0n1p1 /mnt/esp"
echo "  sudo mkdir -p /mnt/esp/EFI/deck-sb"
echo "  sudo cp $OUT_EFI /mnt/esp/EFI/deck-sb/jump.efi"
echo "  sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -l '\\EFI\\deck-sb\\jump.efi' -L 'Deck SB (Custom Jump)'"
echo
echo "Then have your ISO write /EFI/deck-sb/deck-sb.cfg on that same ESP."
