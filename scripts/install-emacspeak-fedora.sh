#!/usr/bin/env bash
# install-emacspeak-fedora.sh: emacspeak with espeak-ng speech on Fedora.
#
# Fedora's default tcl package is Tcl 9, and emacspeak's speech servers and
# their espeak glue only work with Tcl 8.6, which is why a plain build fails.
# Fedora still ships Tcl 8.6 as tcl8, with tcl8-devel and a TclX built for
# it, so this script installs those, builds emacspeak and its espeak server
# against them, and points the servers at tclsh8.6 instead of tclsh.
# For the Eloquence (Voxin) or DECtalk voices, use install-emacspeak-voxin.sh.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
TCLSH=/usr/bin/tclsh8.6
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-fedora.log
PACKAGES=(git make gcc gcc-c++ tcl8 tcl8-devel tclx
          espeak-ng espeak-ng-devel sox pulseaudio-utils)

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-fedora.sh [options]

Installs emacspeak with espeak-ng speech on Fedora 43, 44 or 45.
Run it again later to update emacspeak and rebuild it.

Options:
  --prefix DIR   where emacspeak is cloned and built (default $PREFIX)
  --repo URL     emacspeak git repository (default $REPO)
  --ref REF      branch or tag to build (default $REF)
  --skip-deps    do not run dnf; you installed the packages yourself
  --no-test      skip the self-tests at the end
  --help         show this help

Packages it installs: ${PACKAGES[*]},
and emacs if no Emacs is installed. Build output goes to $LOG.
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
# sub-make then takes for a target and fails. Fedora 43 and later ship make
# 4.4, which is fine, but run make from inside the directory anyway, without
# flags inherited from outside, so this script matches its Debian sibling.
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
[ -r /etc/os-release ] || die "no /etc/os-release; this script is for Fedora"
. /etc/os-release
if [ "${ID:-}" != fedora ]; then
    case " ${ID_LIKE:-} " in
        *" fedora "*) echo "Warning: ${PRETTY_NAME:-this system} is not Fedora itself; trying anyway." ;;
        *) die "this script is for Fedora, and this is ${PRETTY_NAME:-unknown}." ;;
    esac
fi
case "${VERSION_ID:-}" in
    43|44|45) echo "${PRETTY_NAME:-Fedora}: supported." ;;
    *) echo "Warning: tested on Fedora 43 to 45, this is ${VERSION_ID:-unknown}; trying anyway." ;;
esac
: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    # tcl8-devel and tcl-devel (Tcl 9) both own /usr/include/tcl.h.
    if rpm -q --quiet tcl-devel; then
        die "tcl-devel (the Tcl 9 headers) is installed and conflicts with \
tcl8-devel, which this build needs. Remove it with: dnf remove tcl-devel, \
then rerun this script."
    fi
    log "Installing packages with dnf (this can take a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    logged "dnf install" dnf -y install "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        log "No Emacs found: installing Fedora's emacs package"
        logged "dnf install emacs" dnf -y install emacs
    fi
fi

log "Checking Emacs, Tcl 8.6 and TclX"
command -v emacs >/dev/null || die "emacs not found. Install it: dnf install emacs"
EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
    die "emacs is installed but does not run in batch mode"
emacs_new_enough ||
    die "emacspeak needs Emacs 29.1 or newer, and this is Emacs $EMACS_VERSION"
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: ${PACKAGES[*]}"
done
[ -x "$TCLSH" ] || die "$TCLSH not found. Install Tcl 8.6: dnf install tcl8"
grep -q 'define TCL_VERSION[[:space:]]*"8.6"' /usr/include/tcl.h 2>/dev/null ||
    die "/usr/include/tcl.h is missing or is not Tcl 8.6. Install tcl8-devel."
[ -r /usr/include/espeak-ng/speak_lib.h ] ||
    die "espeak-ng headers not found. Install espeak-ng-devel."
TCLX=$(tclx_version 2>>"$LOG") ||
    die "TclX does not load in $TCLSH. Install it: dnf install tclx"
echo "Tcl 8.6 headers found; TclX $TCLX loads in $TCLSH."

# --------------------------------------------------------------------------
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's shebang changes first, so git sees unmodified files.
    for f in "$PREFIX"/servers/*; do
        if [ -f "$f" ] && [ "$(head -n 1 "$f")" = "#!$TCLSH" ]; then
            original=$(git -C "$PREFIX" show "HEAD:servers/${f##*/}" | sed -n 1p) || continue
            sed -i "1s|.*|$original|" "$f"
        fi
    done
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
# tcl8-devel puts the 8.6 headers straight into /usr/include.
logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
    TCL_INCLUDE=/usr/include LIBS="-ltcl8.6 -lespeak-ng"
SO="$PREFIX/servers/native-espeak/tclespeak.so"
[ -f "$SO" ] || die "the build finished but $SO is missing"
echo "Built $SO"

log "Pointing the speech servers at $TCLSH (the default tclsh is Tcl 9)"
changed=""
for f in "$PREFIX"/servers/*; do
    [ -f "$f" ] || continue
    case "$(head -n 1 "$f")" in
        '#!'*tclsh*) sed -i "1s|.*|#!$TCLSH|" "$f"; changed="$changed ${f##*/}" ;;
    esac
done
[ -n "$changed" ] || die "no Tcl speech servers found in $PREFIX/servers"
echo "Changed:$changed"

log "Writing the launcher $LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak, speaking through espeak-ng.
# Written by install-emacspeak-fedora.sh. DTK_PROGRAM picks the speech server.
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
Speech server: espeak, run by $TCLSH
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
