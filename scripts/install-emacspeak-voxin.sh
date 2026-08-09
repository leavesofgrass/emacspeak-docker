#!/bin/sh
# install-emacspeak-voxin.sh
#
# One-shot installer: emacspeak with the Outloud (IBM ViaVoice / Eloquence)
# speech server, driven by a Voxin 3.x archive, on a bare-metal Debian-family
# system. Optionally also builds software DECtalk (--with-dectalk).
#
# Usage:
#   sudo ./install-emacspeak-voxin.sh /path/to/voxin-enu-v3.3rc4.tar.gz [options]
#
# Options:
#   --with-dectalk        also build the software DECtalk server (dtk-soft)
#   --emacspeak-dir DIR   where emacspeak lives          (default /opt/emacspeak)
#   --emacspeak-ref REF   emacspeak git branch/tag       (default master)
#   --skip-deps           don't apt-get anything (you installed deps yourself)
#   --help
#
# What you get: an `emacspeak` command that starts console Emacs talking with
# Eloquence, plus (optionally) DECtalk selectable via DTK_PROGRAM=dtk-soft.
# Every step is explained in GUIDE.md next to this script.

set -e

VOXIN_TGZ=""
EMACSPEAK_DIR=/opt/emacspeak
EMACSPEAK_REF=master
DECTALK_REF=develop
WITH_DECTALK=no
SKIP_DEPS=no

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --with-dectalk)  WITH_DECTALK=yes ;;
        --emacspeak-dir) EMACSPEAK_DIR="$2"; shift ;;
        --emacspeak-ref) EMACSPEAK_REF="$2"; shift ;;
        --skip-deps)     SKIP_DEPS=yes ;;
        --help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *)  VOXIN_TGZ="$1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "run me as root (sudo)"
[ -n "$VOXIN_TGZ" ] || die "point me at your Voxin archive: $0 /path/to/voxin-*.tar.gz"
[ -f "$VOXIN_TGZ" ] || die "no such file: $VOXIN_TGZ"

# --------------------------------------------------------------------------
# 1. Dependencies.
#    i386 runtime libs are for Voxin's 32-bit voxind engine process.
#    tclx8.4 is the TclX extension every emacspeak speech server requires.
#    tcl8.6-dev + g++ + libasound2-dev compile atcleci.so, the Tcl<->ECI glue.
if [ "$SKIP_DEPS" = no ]; then
    command -v apt-get >/dev/null || \
        die "no apt-get here; install equivalents yourself and rerun with --skip-deps"
    log "Installing packages"
    dpkg --add-architecture i386
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git ca-certificates make gcc g++ file unzip xz-utils \
        tcl tcl8.6 tcl8.6-dev tclx8.4 \
        libasound2-dev sox libsox-fmt-all pulseaudio-utils \
        libc6:i386 libstdc++6:i386
    command -v emacs >/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends emacs-nox
fi

EMACS_MAJOR=$(emacs --batch --eval '(princ emacs-major-version)' 2>/dev/null || echo 0)
[ "$EMACS_MAJOR" -ge 29 ] || \
    die "emacspeak needs Emacs 29.1+, found major version '$EMACS_MAJOR'. \
Install a newer Emacs (Debian 13, backports, or build it) and rerun."

# --------------------------------------------------------------------------
# 2. Voxin. The archive is an installer tree; we do what its installer does,
#    deterministically:
#      rfs_<arch>.txz  -> /opt/oralux/voxin/{lib,bin}   (libvoxin, voxin-say)
#      rfs_all.txz     -> /opt/oralux/voxin/{include,rfs32}  (32-bit world)
#      voxin-viavoice-all_*.txz -> /opt/IBM/ibmtts      (the real engine)
#      voxin-viavoice-<lang>_*.txz -> voice libs + /var/opt/IBM voicedata
log "Unpacking Voxin archive"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar -xf "$VOXIN_TGZ" -C "$STAGE"
INSTALLER=$(find "$STAGE" -name voxin-installer.sh | head -1)
[ -n "$INSTALLER" ] || die "this doesn't look like a Voxin 3.x archive (no voxin-installer.sh)"
TREE=$(dirname "$INSTALLER")
ARCH=$(uname -m)

log "Extracting Voxin runtime (rfs) for $ARCH"
found=no
for t in "$TREE"/packages/all/rfs_*."$ARCH".txz "$TREE"/packages/all/rfs_*.all.txz; do
    [ -e "$t" ] || die "missing expected tarball: $t"
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
    found=yes
done
[ "$found" = yes ] || die "no rfs tarballs found for $ARCH"

log "Extracting ViaVoice engine and voices to /opt/IBM"
for t in "$TREE"/packages/all/voxin-viavoice-all_*.txz; do
    [ -e "$t" ] || die "no voxin-viavoice-all engine tarball in the archive"
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
done
for t in "$TREE"/packages/all/voxin-viavoice-*.txz; do
    case "$t" in *-all_*) continue ;; esac
    echo "  $(basename "$t")"
    tar -C / --no-overwrite-dir -xf "$t"
done

# eci.ini: concatenate the engine's all.ini with one section per installed
# language (a language is present when its xxx50.so synthesizer lib exists).
log "Generating /var/opt/IBM/ibmtts/cfg/eci.ini"
INIDIR=/opt/IBM/ibmtts/etc
NEWCONF=/var/opt/IBM/ibmtts/cfg/eci.ini
mkdir -p "$(dirname "$NEWCONF")"
LANGS=$(find /opt/IBM/ibmtts/lib -name "???50.so" | sed "s+.*/\(...\)50.so+\1+")
[ -n "$LANGS" ] || die "no ViaVoice language libraries found under /opt/IBM/ibmtts/lib"
cp "$INIDIR/all.ini" "$NEWCONF"
for l in $LANGS; do
    echo "  language: $l"
    cat "$INIDIR/$l.ini" >> "$NEWCONF"
done

# Library wiring. libvoxin.so.1 IS the 64-bit ECI shim; Voxin's own deb just
# symlinks the libibmeci.so name to it. dlopen("libibmeci.so") searches the
# trusted dirs directly, so the symlink lives in /usr/lib; the ld.so.conf.d
# entry lets binaries linked against libvoxin.so.1 (voxin-say) resolve it.
log "Wiring libraries"
[ -e /opt/oralux/voxin/lib/libvoxin.so.1 ] || die "libvoxin.so.1 missing after extraction"
ln -sf /opt/oralux/voxin/lib/libvoxin.so.1 /usr/lib/libibmeci.so
echo /opt/oralux/voxin/lib > /etc/ld.so.conf.d/voxin.conf
ldconfig
ln -sf /opt/oralux/voxin/bin/voxin-say /usr/local/bin/voxin-say

# ECIINI tells the engine where its config lives; classic ViaVoice lore, still
# honored. Exported system-wide and again by the emacspeak launcher.
echo 'export ECIINI=/var/opt/IBM/ibmtts/cfg/eci.ini' > /etc/profile.d/voxin.sh

log "Voxin self-test (synthesizes to a wav; no audio device needed)"
rm -f /tmp/voxin-selftest.wav
ECIINI="$NEWCONF" voxin-say -w /tmp/voxin-selftest.wav "Voxin is installed." \
    || die "voxin-say failed to run"
[ -s /tmp/voxin-selftest.wav ] || \
    die "voxin-say wrote a zero-byte wav: libvoxin could not find the engine. \
Check that /opt/IBM/ibmtts/lib/libibmeci.so exists."
echo "  OK: $(stat -c%s /tmp/voxin-selftest.wav) bytes of speech"

# --------------------------------------------------------------------------
# 3. Emacspeak, run in place from $EMACSPEAK_DIR (no `make install` needed).
if [ -d "$EMACSPEAK_DIR/.git" ]; then
    log "Emacspeak already cloned at $EMACSPEAK_DIR; leaving it as is"
else
    log "Cloning emacspeak ($EMACSPEAK_REF) to $EMACSPEAK_DIR"
    git clone --depth 1 --branch "$EMACSPEAK_REF" \
        https://github.com/tvraman/emacspeak.git "$EMACSPEAK_DIR"
fi

log "Building emacspeak (byte-compiling the lisp)"
( cd "$EMACSPEAK_DIR" && make config && make emacspeak )

log "Building atcleci.so (Tcl glue that dlopens libibmeci.so, speaks via ALSA)"
make -C "$EMACSPEAK_DIR/servers/linux-outloud"

# --------------------------------------------------------------------------
# 4. Optional software DECtalk.
if [ "$WITH_DECTALK" = yes ]; then
    log "Building software DECtalk (this is 1990s C; gcc needs -fpermissive)"
    if [ "$SKIP_DEPS" = no ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            build-essential autoconf automake libpulse-dev libpulse0
    fi
    DTKSRC=$(mktemp -d)
    git clone --depth 1 --branch "$DECTALK_REF" \
        https://github.com/dectalk/dectalk.git "$DTKSRC/dectalk"
    ( cd "$DTKSRC/dectalk/src" \
      && ./autogen.sh \
      && ./configure CFLAGS="-O2 -fpermissive -Wno-implicit-function-declaration" \
      && make -j"$(nproc)" )
    mkdir -p /opt/dectalk
    cp -a "$DTKSRC/dectalk/dist/." /opt/dectalk/
    mkdir -p /opt/dectalk/include/dtk
    cp "$DTKSRC/dectalk/src/dapi/src/include/"*.h /opt/dectalk/include/dtk/
    rm -rf "$DTKSRC"
    [ -e /opt/dectalk/lib/libtts.so ] || \
        ln -s libtts_us.so /opt/dectalk/lib/libtts.so
    echo /opt/dectalk/lib > /etc/ld.so.conf.d/dectalk.conf
    ldconfig
    # libtts falls back to <prefix>/DECtalk.conf; emacspeak ships a template
    # whose dictionary paths are already absolute /opt/dectalk/dic entries.
    cp "$EMACSPEAK_DIR/servers/software-dtk/DECtalk.conf" /opt/dectalk/DECtalk.conf
    log "Building tcldtk.so (Tcl glue for the dtk-soft server)"
    make -C "$EMACSPEAK_DIR/servers/software-dtk" \
        CFLAGS="-g -O2 -fPIC -DPIC -I/usr/include/tcl8.6 -I/opt/dectalk/include" \
        LDFLAGS="-L/opt/dectalk/lib"
    log "DECtalk self-test"
    /opt/dectalk/say -fo /tmp/dectalk-selftest.wav -a "DECtalk is installed."
    [ -s /tmp/dectalk-selftest.wav ] || die "DECtalk say produced no audio data"
    echo "  OK: $(stat -c%s /tmp/dectalk-selftest.wav) bytes of speech"
fi

# --------------------------------------------------------------------------
# 5. Launcher.
log "Installing /usr/local/bin/emacspeak launcher"
cat > /usr/local/bin/emacspeak <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak. DTK_PROGRAM selects the speech server:
# outloud (Eloquence, default) or dtk-soft (software DECtalk).
export EMACSPEAK_DIR="$EMACSPEAK_DIR"
export DTK_PROGRAM="\${DTK_PROGRAM:-outloud}"
export ECIINI="\${ECIINI:-/var/opt/IBM/ibmtts/cfg/eci.ini}"
exec emacs -nw -l "$EMACSPEAK_DIR/lisp/emacspeak-setup.el" "\$@"
LAUNCHER
chmod 0755 /usr/local/bin/emacspeak

log "All done"
cat <<DONE

  Start it:            emacspeak
  DECtalk instead:     DTK_PROGRAM=dtk-soft emacspeak   (if --with-dectalk)
  Engine self-test:    voxin-say -w /tmp/t.wav "hello"

  To load emacspeak in your own Emacs config instead of the launcher, put
  this FIRST in ~/.emacs (before anything that produces output):

    (setenv "DTK_PROGRAM" "outloud")
    (load-file "$EMACSPEAK_DIR/lisp/emacspeak-setup.el")

DONE
