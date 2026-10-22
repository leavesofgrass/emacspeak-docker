#!/usr/bin/env bash
# install-emacspeak-arch.sh: emacspeak with espeak-ng speech on Arch Linux
# and its family (CachyOS, EndeavourOS, Manjaro).
#
# Emacspeak's speech servers are Tcl scripts that need Tcl 8.6 and TclX.
# Arch's tcl package is still Tcl 8.6 (8.6.16 when this was written, in
# October 2026), so the servers' #!/usr/bin/tclsh line already finds the
# right Tcl and no shebang needs changing. Arch does not package TclX,
# though, so this script builds TclX from source when it is missing, then
# builds emacspeak and its espeak server against Arch's Tcl 8.6.
# For the Eloquence (Voxin) or DECtalk voices, use install-emacspeak-voxin.sh.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
TCLSH=/usr/bin/tclsh
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-arch.log
# gcc includes g++, and libpulse provides paplay and pactl. Arch's tcl and
# espeak-ng packages include their headers; there are no -devel packages.
PACKAGES=(git make gcc tcl espeak-ng sox libpulse)
# TclX is pinned to a release tag, which ships its configure script, so
# autoconf is not needed. TCLX_DIR is where its package folder ends up.
TCLX_REPO=https://github.com/flightaware/tclx.git
TCLX_REF=v8.6.3
TCLX_DIR=/usr/lib/tclx8.6

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-arch.sh [options]

Installs emacspeak with espeak-ng speech on Arch Linux, CachyOS,
EndeavourOS or Manjaro.
Run it again later to update emacspeak and rebuild it.

Options:
  --prefix DIR   where emacspeak is cloned and built (default $PREFIX)
  --repo URL     emacspeak git repository (default $REPO)
  --ref REF      branch or tag to build (default $REF)
  --skip-deps    do not run pacman; you installed the packages yourself
  --no-test      skip the self-tests at the end
  --help         show this help

Packages it installs: ${PACKAGES[*]},
and emacs if no Emacs is installed. Arch supports only full upgrades,
so installing them also upgrades the whole system (pacman -Syu).
Arch does not package TclX: when it is missing, this script builds it
from source into $TCLX_DIR, even with --skip-deps.
Build output goes to $LOG.
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Run a noisy command with its output in $LOG. If it fails, show the end of
# the log, then the error, so the last line on screen names the problem.
logged() {
    local what=$1; shift
    if ! "$@" >>"$LOG" 2>&1; then
        printf '\nLast lines of %s:\n' "$LOG" >&2
        tail -n 20 "$LOG" >&2
        die "$what failed. The full output is in $LOG"
    fi
}

# Emacspeak's Makefiles hand $(MAKEFLAGS) to their sub-makes as plain words.
# GNU make 4.3 writes the -w that "make -C" adds as a bare "w", which the
# sub-make then takes for a target and fails; a MAKEFLAGS such as -s set in
# the environment does the same. Arch ships make 4.4, which is fine, but run
# make from inside the directory anyway, without flags inherited from
# outside, so this script matches its Debian and Fedora siblings.
make_in() { # $1 = directory, then the make arguments
    local dir=$1; shift
    ( cd "$dir" && env -u MAKEFLAGS -u MFLAGS make "$@" )
}

# tclsh reading a script from stdin exits 0 even after an error, so these
# Tcl checks exit 1 themselves when something fails.
tclx_version() {
    echo 'if {[catch {puts [package require Tclx]}]} {exit 1}' | "$TCLSH"
}
espeak_glue_check() { # $1 = path of tclespeak.so
    timeout 30 "$TCLSH" <<TCL
if {[catch {load {$1}} err]} {puts stderr \$err; exit 1}
if {[info commands say] ne "say"} {puts stderr "no say command"; exit 1}
puts "eSpeak NG [ttsVersion], voice data in [ttsDataPath]"
TCL
}
emacs_new_enough() {
    emacs -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}

need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    need_value "$@"; PREFIX=$2; shift ;;
        --repo)      need_value "$@"; REPO=$2; shift ;;
        --ref)       need_value "$@"; REF=$2; shift ;;
        --skip-deps) SKIP_DEPS=yes ;;
        --no-test)   RUN_TESTS=no ;;
        --help|-h)   usage; exit 0 ;;
        *)           die "unknown option $1 (try --help)" ;;
    esac
    shift
done
PREFIX=$(realpath -m "$PREFIX")

# --------------------------------------------------------------------------
log "Checking the system"
[ "$EUID" -eq 0 ] || die "run this as root, for example: sudo bash $0"
[ -r /etc/os-release ] || die "no /etc/os-release; this script is for Arch Linux"
. /etc/os-release
case "${ID:-}" in
    arch|cachyos|endeavouros|manjaro)
        echo "${PRETTY_NAME:-$ID}: supported." ;;
    *)
        case " ${ID_LIKE:-} " in
            *" arch "*) echo "Warning: ${PRETTY_NAME:-this system} is based on Arch but untested; trying anyway." ;;
            *) die "this script is for Arch Linux and its family, and this is ${PRETTY_NAME:-unknown}." ;;
        esac ;;
esac
command -v pacman >/dev/null || die "pacman not found; this script is for Arch Linux"
: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    # Arch does not support partial upgrades: refreshing the package lists
    # without upgrading (pacman -Sy) and then installing can break other
    # programs. So the install and a full upgrade happen in one -Syu step.
    log "Upgrading the system and installing packages with pacman (a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    echo "Arch supports only full upgrades, so the rest of the system is upgraded too."
    logged "pacman -Syu" pacman -Syu --noconfirm --needed --noprogressbar "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        # The emacs package is the graphical (GTK) build. emacs-nox, for the
        # console only and with fewer dependencies, and emacs-wayland also
        # provide the emacs command: install one first if you prefer it.
        log "No Emacs found: installing Arch's emacs package"
        logged "pacman -S emacs" pacman -S --noconfirm --needed --noprogressbar emacs
    fi
fi

log "Checking Emacs and Tcl 8.6"
command -v emacs >/dev/null || die "emacs not found. Install it: pacman -Syu emacs"
EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
    die "emacs is installed but does not run in batch mode"
emacs_new_enough ||
    die "emacspeak needs Emacs 29.1 or newer, and this is Emacs $EMACS_VERSION"
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: pacman -Syu ${PACKAGES[*]}"
done
[ -x "$TCLSH" ] || die "$TCLSH not found. Install Tcl 8.6: pacman -Syu tcl"
TCL_PATCH=$(echo 'puts [info patchlevel]' | "$TCLSH" 2>>"$LOG") || TCL_PATCH=""
case "$TCL_PATCH" in
    8.6.*) ;;
    *) die "emacspeak needs Tcl 8.6, and $TCLSH is Tcl ${TCL_PATCH:-unknown}. \
If Arch's tcl package has moved to Tcl 9, this script cannot handle that yet." ;;
esac
grep -q 'define TCL_VERSION[[:space:]]*"8.6"' /usr/include/tcl.h 2>/dev/null ||
    die "/usr/include/tcl.h is missing or is not Tcl 8.6. It comes with tcl: pacman -Syu tcl"
[ -r /usr/include/espeak-ng/speak_lib.h ] ||
    die "espeak-ng headers not found. They come with espeak-ng: pacman -Syu espeak-ng"
echo "Tcl $TCL_PATCH at $TCLSH, with its headers in /usr/include."

log "Checking TclX, the Tcl extension the speech servers need"
if TCLX=$(tclx_version 2>>"$LOG"); then
    echo "TclX $TCLX loads in $TCLSH: already installed."
    TCLX_NOTE="$TCLX, already installed"
else
    echo "TclX is missing. Arch does not package it, so it is built next."
    log "Building TclX ${TCLX_REF#v} from source"
    [ -r /usr/lib/tclConfig.sh ] ||
        die "/usr/lib/tclConfig.sh not found. It comes with tcl: pacman -Syu tcl"
    TCLX_SRC=$(mktemp -d /tmp/emacspeak-tclx.XXXXXXXX)
    echo "Source: $TCLX_REPO, tag $TCLX_REF"
    logged "cloning TclX" git -c advice.detachedHead=false clone -q --depth 1 \
        --branch "$TCLX_REF" "$TCLX_REPO" "$TCLX_SRC"
    # Arch's tclsh looks for packages only in /usr/lib/tcl8.6 and /usr/lib
    # (its auto_path; /usr/local is not on it), so --libdir=/usr/lib puts
    # TclX's package folder in /usr/lib/tclx8.6. Its header and man page go
    # under /usr/local. pacman does not track these files.
    (cd "$TCLX_SRC" && logged "configuring TclX" ./configure \
        --with-tcl=/usr/lib --prefix=/usr/local --libdir=/usr/lib)
    logged "building TclX" make_in "$TCLX_SRC"
    logged "installing TclX" make_in "$TCLX_SRC" install
    [ -f "$TCLX_DIR/pkgIndex.tcl" ] ||
        die "TclX was installed, but $TCLX_DIR/pkgIndex.tcl is missing. See $LOG"
    TCLX=$(tclx_version 2>>"$LOG") ||
        die "TclX was installed in $TCLX_DIR but does not load in $TCLSH. See $LOG"
    echo "TclX $TCLX installed in $TCLX_DIR; it loads in $TCLSH."
    echo "The build folder $TCLX_SRC is no longer needed; /tmp is emptied at reboot."
    TCLX_NOTE="$TCLX, built from source into $TCLX_DIR (pacman does not track it)"
fi

# --------------------------------------------------------------------------
# This script changes no tracked file in the clone (the shebangs are left
# alone), so a fast-forward pull is all an update needs.
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"

log "Configuring emacspeak (make config)"
logged "make config" make_in "$PREFIX" config

log "Byte-compiling emacspeak's Lisp (make emacspeak, a few minutes)"
logged "make emacspeak" make_in "$PREFIX" emacspeak

log "Building tclespeak.so, the espeak glue, against Tcl 8.6"
# Arch's tcl package puts the 8.6 headers straight into /usr/include.
logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
    TCL_INCLUDE=/usr/include LIBS="-ltcl8.6 -lespeak-ng"
SO="$PREFIX/servers/native-espeak/tclespeak.so"
[ -f "$SO" ] || die "the build finished but $SO is missing"
echo "Built $SO"

log "Writing the launcher $LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak, speaking through espeak-ng.
# Written by install-emacspeak-arch.sh. DTK_PROGRAM picks the speech server.
export EMACSPEAK_DIR="$PREFIX"
export DTK_PROGRAM="\${DTK_PROGRAM:-espeak}"
exec emacs -nw -l "$PREFIX/lisp/emacspeak-setup.el" "\$@"
LAUNCHER
chmod 0755 "$LAUNCHER"
echo "Launcher written."

# --------------------------------------------------------------------------
# Self-tests. None of them needs a sound card.
if [ "$RUN_TESTS" = yes ]; then
    log "Self-test 1 of 5: TclX loads in $TCLSH"
    TCLX=$(tclx_version 2>>"$LOG") ||
        die "Self-test 1 failed: TclX does not load in $TCLSH"
    echo "Pass: TclX $TCLX."

    log "Self-test 2 of 5: tclespeak.so loads in $TCLSH"
    INFO=$(espeak_glue_check "$SO" 2>>"$LOG") ||
        die "Self-test 2 failed: $SO does not load. See $LOG"
    echo "Pass: $INFO."

    log "Self-test 3 of 5: the espeak server starts the way Emacs starts it"
    timeout 30 "$PREFIX/servers/espeak" </dev/null >>"$LOG" 2>&1 ||
        die "Self-test 3 failed: $PREFIX/servers/espeak did not run. See $LOG"
    echo "Pass: the server started and exited cleanly."

    log "Self-test 4 of 5: espeak-ng synthesizes speech (into a pipe)"
    BYTES=$(espeak-ng --stdout "Emacspeak is installed." 2>>"$LOG" | wc -c) || BYTES=0
    [ "$BYTES" -gt 1000 ] || die "Self-test 4 failed: espeak-ng produced no audio"
    echo "Pass: $BYTES bytes of audio."

    log "Self-test 5 of 5: Emacs is 29.1 or newer"
    emacs_new_enough || die "Self-test 5 failed: Emacs $EMACS_VERSION is too old"
    echo "Pass: Emacs $EMACS_VERSION."
    TESTS="all 5 passed"
else
    TESTS="skipped (--no-test)"
fi

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
cat <<DONE
Self-tests: $TESTS
Emacspeak is in $PREFIX
Speech server: espeak, run by $TCLSH (Tcl $TCL_PATCH)
TclX: $TCLX_NOTE
Launcher: $LAUNCHER
Build log: $LOG

To start it, run this as your normal user (not root):
  emacspeak

The launcher sets DTK_PROGRAM=espeak, which picks the espeak server.
To load emacspeak from your own Emacs init file instead, put these
two lines at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (setenv "DTK_PROGRAM" "espeak")
  (load-file "$PREFIX/lisp/emacspeak-setup.el")

To update emacspeak later, run this script again.
DONE
