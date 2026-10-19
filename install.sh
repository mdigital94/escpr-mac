#!/bin/bash
# escpr-mac: native Apple Silicon build of the Epson ESC/P-R inkjet driver
#
# Downloads the open source Epson ESC/P-R driver (v1.8.9), patches it for the
# macOS compiler, builds it natively for arm64 (M1 and later), installs it in
# /Library/Printers/ESCPR and creates a print queue. No Rosetta needed.
#
# Usage:
#   bash install.sh                    detect a USB Epson printer and set it up
#   bash install.sh --model "XP-600"   install the driver for a given model
#   bash install.sh --uri "socket://192.168.1.50" --model "XP-600"
#   bash install.sh --list [filter]    list supported models
#   bash install.sh --driver-only      build and install, create no queue
#   bash install.sh --uninstall        remove driver, PPDs and its queues
#
# License: GPL-2.0-or-later (same as the Epson driver it builds).

set -euo pipefail
# The Epson sources contain non UTF-8 bytes that make macOS sed/awk fail
export LC_ALL=C

# Pinned source with verified checksum
COMMIT="8e9d6ead3924c98f0545017d30844e0f1dcfeed2"
SOURCE_URL="https://codeload.github.com/vmartins/epson-inkjet-printer-escpr/tar.gz/${COMMIT}"
SOURCE_SHA256="8d126bd5dcb44cb1dd7e82c491032e3aaf0a63890a8a415319ec704703977e35"

DEST="/Library/Printers/ESCPR"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources/ESCPR"
NICK_SUFFIX="ESC/P-R (Apple Silicon)"

step()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
fail()  { printf "\n\033[31mERROR: %s\033[0m\n" "$1" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Arguments
MODEL_ARG=""; URI_ARG=""; MODE="install"; LIST_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)       [ $# -ge 2 ] || usage 1; MODEL_ARG="$2"; shift 2 ;;
    --uri)         [ $# -ge 2 ] || usage 1; URI_ARG="$2"; shift 2 ;;
    --list)        MODE="list"; shift; if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then LIST_FILTER="$1"; shift; fi ;;
    --driver-only) MODE="driver"; shift ;;
    --uninstall)   MODE="uninstall"; shift ;;
    -h|--help)     usage 0 ;;
    *)             echo "Unknown option: $1"; usage 1 ;;
  esac
done
[ -n "$URI_ARG" ] && [ -z "$MODEL_ARG" ] && fail "--uri needs --model as well."

[ "$(uname -s)" = "Darwin" ] || fail "This script is for macOS."

# Uninstall
if [ "$MODE" = "uninstall" ]; then
  echo "Administrator password may be requested."
  sudo -v || fail "Administrator rights not granted."
  for q in $(lpstat -e 2>/dev/null || true); do
    if lpoptions -p "$q" 2>/dev/null | grep -qF "$NICK_SUFFIX"; then
      echo "Removing queue: $q"; sudo lpadmin -x "$q" || true
    fi
  done
  sudo rm -rf "$DEST" "$PPD_DIR"
  echo "Driver and PPDs removed."
  exit 0
fi

[ "$(uname -m)" = "arm64" ] || fail "This script targets Apple Silicon Macs (M1 and later)."

WORK="$(mktemp -d /tmp/escpr_build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^epson//' | tr -cd 'a-z0-9'; }
urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# 1. Source
step "1/7  Downloading the driver source"
curl -fsSL -o "$WORK/escpr.tar.gz" "$SOURCE_URL" || fail "Download failed. Check your connection."
GOT_SHA256="$(shasum -a 256 "$WORK/escpr.tar.gz" | awk '{print $1}')"
[ "$GOT_SHA256" = "$SOURCE_SHA256" ] || fail "Checksum mismatch, stopping for safety.
Expected: $SOURCE_SHA256
Got:      $GOT_SHA256"
echo "SHA-256 verified."
tar xzf "$WORK/escpr.tar.gz" -C "$WORK"
SRC="$WORK/epson-inkjet-printer-escpr-${COMMIT}"

# Model index: normalized name, PPD file, display name
for f in "$SRC"/ppd/*.ppd; do
  name="$(sed -n 's/^\*ModelName:[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -n1)"
  if [ -n "$name" ]; then printf '%s\t%s\t%s\n' "$(norm "$name")" "$f" "$name"; fi
done > "$WORK/index.tsv"

if [ "$MODE" = "list" ]; then
  q="$(norm "$LIST_FILTER")"
  awk -F'\t' -v q="$q" 'q=="" || index($1,q){print $3}' "$WORK/index.tsv" | sort -f
  echo "$(awk -F'\t' -v q="$q" 'q=="" || index($1,q)' "$WORK/index.tsv" | wc -l | tr -d ' ') model(s)."
  exit 0
fi

# Finds the PPD for a model name; prints "file<TAB>name" or nothing
find_ppd() {
  local q; q="$(norm "$1")"
  [ -n "$q" ] || return 0
  local hit
  hit="$(awk -F'\t' -v q="$q" '$1==q || $1==q"series"{print $2"\t"$3; exit}' "$WORK/index.tsv")"
  if [ -z "$hit" ]; then
    local qs="${q%series}"
    hit="$(awk -F'\t' -v q="$qs" '{n=$1; sub(/series$/,"",n)} n==q{print $2"\t"$3; exit}' "$WORK/index.tsv")"
  fi
  if [ -z "$hit" ] && [ "$(awk -F'\t' -v q="$q" 'index($1,q)' "$WORK/index.tsv" | wc -l)" -eq 1 ]; then
    hit="$(awk -F'\t' -v q="$q" 'index($1,q){print $2"\t"$3}' "$WORK/index.tsv")"
  fi
  printf '%s' "$hit"
}

echo "Administrator password may be requested."
sudo -v || fail "Administrator rights not granted."

# 2. Which printer
step "2/7  Looking for the printer"
PPD_SRC=""; MODEL_NAME=""; URI=""
if [ -n "$MODEL_ARG" ]; then
  HIT="$(find_ppd "$MODEL_ARG")"
  if [ -z "$HIT" ]; then
    echo "Models matching \"$MODEL_ARG\":"
    awk -F'\t' -v q="$(norm "$MODEL_ARG")" 'index($1,q){print "  "$3}' "$WORK/index.tsv" | head -n 20
    fail "No unique match for \"$MODEL_ARG\". Use --list to see all models."
  fi
  PPD_SRC="${HIT%%$'\t'*}"; MODEL_NAME="${HIT#*$'\t'}"
  URI="$URI_ARG"
fi
if [ "$MODE" = "install" ] && [ -z "$URI" ]; then
  USB_URIS="$(sudo lpinfo --include-schemes usb -v 2>/dev/null | awk '{print $2}' | grep -i '^usb://epson/' || true)"
  for u in $USB_URIS; do
    usb_model="$(urldecode "$(printf '%s' "$u" | sed -E 's|^usb://[^/]+/||; s|\?.*$||')")"
    HIT="$(find_ppd "$usb_model")"
    [ -n "$HIT" ] || { echo "Found $usb_model on USB, not an ESC/P-R model."; continue; }
    if [ -z "$PPD_SRC" ] || [ "${HIT%%$'\t'*}" = "$PPD_SRC" ]; then
      PPD_SRC="${HIT%%$'\t'*}"; MODEL_NAME="${HIT#*$'\t'}"; URI="$u"; break
    fi
  done
fi
[ -n "$PPD_SRC" ] || fail "No supported Epson printer found on USB.
Connect and switch it on, or name it: bash install.sh --model \"<model>\""
echo "Model: $MODEL_NAME"
if [ -n "$URI" ]; then echo "Connection: $URI"
elif [ "$MODE" = "install" ]; then echo "Printer not connected: installing the driver only."; MODE="driver"; fi

# 3. Build tools
step "3/7  Checking Apple developer tools"
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  fail "Xcode Command Line Tools are required. An installer window has opened:
finish it (a few minutes) and run this script again."
fi
echo "Compiler: $(xcrun --find clang)"

# 4. Patches for macOS / arm64
step "4/7  Patching the source for macOS"
cd "$SRC"
insert_after() { # file, anchor line, text
  grep -q "MACFIX" "$1" && return 0
  printf '%s\n' "$3" > "$WORK/insert.txt"
  awk -v a="$2" -v f="$WORK/insert.txt" \
    '{print} $0==a{while((getline l < f) > 0) print l; close(f)}' "$1" > "$1.tmp" \
    && mv "$1.tmp" "$1"
}
# Missing prototypes: implicit declarations are errors in Apple clang and unsafe on arm64
insert_after src/mem.c '#include "mem.h"' '#include "err.h" /* MACFIX */'
insert_after src/wrapper.c '#include "libprtX.h"' '#include "custompage.h" /* MACFIX */'
insert_after src/filter.c '#include "custompage.h"' '/* MACFIX */
extern void obsClear(void);
extern EPS_ERR_CODE SetupJobAttrib(const EPS_JOB_ATTRIB*);
extern EPS_ERR_CODE SendStartJob(EPS_BOOL);
extern EPS_ERR_CODE PrintBand(const EPS_UINT8*, EPS_UINT32, EPS_UINT32*);'
# jobFnc is defined in both the filter and the library; Apple's linker rejects it
grep -q "MACFIX2" src/filter.c || \
  sed -i '' 's|^EPS_JOB_FUNCS[[:space:]]*jobFnc;|extern EPS_JOB_FUNCS jobFnc; /* MACFIX2 */|' src/filter.c
# Unix only code is gated on the "unix" macro, which Apple clang does not define
for f in $(grep -l "(__unix)" src/*.c src/*.h lib/*.c lib/*.h); do
  grep -q "__APPLE__" "$f" || sed -i '' 's/(__unix)/(__unix) || defined(__APPLE__)/' "$f"
done
# Read the PPD path CUPS passes in $PPD instead of querying cupsd from the sandbox
grep -q 'getenv("PPD")' src/wrapper.c || \
  sed -i '' 's|cupsGetPPD (printer);|(getenv("PPD") ? getenv("PPD") : cupsGetPPD (printer));|' src/wrapper.c
for f in src/mem.c src/wrapper.c src/filter.c; do grep -q "MACFIX" "$f" || fail "Patch not applied to $f"; done
grep -q "MACFIX2" src/filter.c || fail "jobFnc patch not applied"
grep -q "__APPLE__" src/linux_cmn.c && grep -q "__APPLE__" lib/epson-typedefs.h || fail "Unix patch not applied"
grep -q 'getenv("PPD")' src/wrapper.c || fail "PPD patch not applied"
echo "Patches applied."
# Keep make from trying to regenerate the autotools files
touch aclocal.m4 m4-macros; sleep 1
touch configure config.h.in Makefile.in ./*/Makefile.in

# 5. Native build
step "5/7  Building for arm64 (a couple of minutes)"
export CC="clang" CFLAGS="-O2 -arch arm64 -Wno-deprecated-declarations" LIBS="-lcups"
./configure --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
  --disable-shared --enable-static --disable-lsb --prefix="$DEST" \
  --with-cupsfilterdir="$DEST/filter" --with-cupsppddir="$DEST/ppd" > "$WORK/configure.log" 2>&1 \
  || { cp "$WORK/configure.log" "$HOME/Downloads/escpr_configure.log" 2>/dev/null || true
       tail -n 30 "$WORK/configure.log"; fail "configure failed. Log saved to ~/Downloads/escpr_configure.log"; }
if ! make -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1; then
  cp "$WORK/make.log" "$HOME/Downloads/escpr_make.log" 2>/dev/null || true
  grep -v "warning:\|note:\|^ *[0-9]* |\|^ *|" "$WORK/make.log" | tail -n 25
  fail "Build failed. Full log saved to ~/Downloads/escpr_make.log"
fi
for b in src/epson-escpr src/epson-escpr-wrapper; do
  [ -x "$b" ] || fail "Missing build output $b"
  [ "$(lipo -archs "$b")" = "arm64" ] || fail "$b was not built for arm64"
done
echo "Build OK: native arm64 binaries."

# 6. Install
step "6/7  Installing to $DEST"
sudo mkdir -p "$DEST/filter" "$PPD_DIR"
sudo install -m 755 -o root -g wheel src/epson-escpr src/epson-escpr-wrapper "$DEST/filter/"
sudo chown root:wheel "$DEST" "$DEST/filter" "$PPD_DIR"
sudo chmod 755 "$DEST" "$DEST/filter" "$PPD_DIR"
PPD_FINAL="$PPD_DIR/$(basename "$PPD_SRC" | sed 's/-epson-escpr-en\.ppd$/-escpr-arm64.ppd/')"
sed -e "s|0 epson-escpr-wrapper\"|0 $DEST/filter/epson-escpr-wrapper\"|" \
    -e "s|^\*NickName:.*|*NickName:              \"$MODEL_NAME, $NICK_SUFFIX\"|" \
    "$PPD_SRC" > "$WORK/model.ppd"
grep -q "$DEST/filter/epson-escpr-wrapper" "$WORK/model.ppd" || fail "PPD rewrite failed."
sudo install -m 644 -o root -g wheel "$WORK/model.ppd" "$PPD_FINAL"
echo "Driver and PPD installed."

# 7. Print queue
if [ "$MODE" = "driver" ]; then
  printf "\n\033[32mDone. Driver installed for %s.\033[0m\n" "$MODEL_NAME"
  echo "Add the printer in System Settings > Printers & Scanners and pick"
  echo "\"$MODEL_NAME, $NICK_SUFFIX\" as the driver, or rerun with --uri."
  exit 0
fi
step "7/7  Creating the print queue"
QUEUE="$(printf '%s' "$MODEL_NAME" | tr -c 'A-Za-z0-9\n' '_' | sed 's/__*/_/g; s/_$//')"
# Old queues for the same model (e.g. a generic driver that cannot talk to it):
# matched on the model code, like "sx218" or "xp600", in their name, URI or model
TOKEN="$(printf '%s' "$MODEL_NAME" | sed -E 's/^[Ee][Pp][Ss][Oo][Nn] //; s/ [Ss]eries$//' | awk '{print $NF}' | tr '[:upper:]' '[:lower:]' | tr -d -c 'a-z0-9')"
for q in $(lpstat -e 2>/dev/null || true); do
  info="$(printf '%s %s' "$q" "$(lpoptions -p "$q" 2>/dev/null || true)" | sed 's/%20/ /g' | tr '[:upper:]' '[:lower:]' | tr '_' ' ' | tr -d '-')"
  if [ "$q" = "$QUEUE" ] || printf '%s' "$info" | grep -qE "(^|[^a-z0-9])${TOKEN}([^0-9]|$)"; then
    echo "Removing old queue: $q"; sudo lpadmin -x "$q" || true
  fi
done
sudo lpadmin -p "$QUEUE" -D "$MODEL_NAME" -E -v "$URI" -P "$PPD_FINAL" \
  -o printer-is-shared=false || fail "Could not create the queue."
sudo cupsenable "$QUEUE"; sudo cupsaccept "$QUEUE"
lpstat -p "$QUEUE" || true
printf "\n\033[32mDone. %s is ready with a native arm64 driver.\033[0m\n" "$MODEL_NAME"

read -r -p "Print a test page? [y/N] " ANSWER || true
if [[ "${ANSWER:-}" =~ ^[yYsS]$ ]]; then
  printf "Test page\n%s\nESC/P-R native Apple Silicon\n%s\n" "$MODEL_NAME" "$(date)" \
    | lp -d "$QUEUE" -t "escpr-mac test"
  echo "Sent. If it stays in the queue, check:"
  echo "  grep -i \"escpr\\|sandbox\" /var/log/cups/error_log | tail -n 40"
fi
