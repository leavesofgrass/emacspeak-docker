#!/usr/bin/env bash
# install-emacspeak-debian.sh: emacspeak with espeak-ng speech on Debian,
# Ubuntu and Linux Mint.
#
# Emacspeak's speech servers and their espeak glue only work with Tcl 8.6
# and TclX. Debian and Ubuntu package both (tcl8.6, tcl8.6-dev, tclx8.4),
# and Tcl 8.6 is their default tclsh, so the build works with the stock
# layout. The script still checks which Tcl /usr/bin/tclsh runs, and if it
# is not 8.6, points the servers at tclsh8.6 instead, as the Fedora script
# does. Emacspeak needs Emacs 29.1 or newer: Debian 13 and Ubuntu 24.04 have
# it, Debian 12 and Ubuntu 22.04 do not, and the script stops early there.
# For the Eloquence (Voxin) or DECtalk voices, use install-emacspeak-voxin.sh.

set -euo pipefail

PREFIX=/opt/emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
TCLSH86=/usr/bin/tclsh8.6
TCL_INCLUDE=/usr/include/tcl8.6
LAUNCHER=/usr/local/bin/emacspeak
LOG=/var/log/install-emacspeak-debian.log
# ca-certificates lets git clone over https; apt only recommends it for git.
PACKAGES=(git ca-certificates make gcc g++ tcl8.6 tcl8.6-dev tclx8.4
          espeak-ng libespeak-ng-dev sox libsox-fmt-all pulseaudio-utils)
# Emacs is installed only when there is none. The emacs package is the GTK
# build, which also runs in a console. emacs-nox is the console-only build:
# to use it instead, install it yourself before running this script.

usage() {
    cat <<USAGE
Usage: sudo bash install-emacspeak-debian.sh [options]

Installs emacspeak with espeak-ng speech on Debian 13 or Ubuntu 24.04,
and on relatives built on them, such as Linux Mint 22.
Run it again later to update emacspeak and rebuild it.

Options:
  --prefix DIR   where emacspeak is cloned and built (default $PREFIX)
  --repo URL     emacspeak git repository (default $REPO)
  --ref REF      branch or tag to build (default $REF)
  --skip-deps    do not run apt-get; you installed the packages yourself
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

# No questions from package scripts, and if another package manager (such
# as an automatic update) holds the lock, wait for it up to five minutes.
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=300 "$@"
}
apt_candidate() { # $1 = package; prints the version apt would install
    apt-cache policy "$1" 2>>"$LOG" |
        awk '$1 == "Candidate:" && $2 != "(none)" { print $2 }'
}

# Emacspeak's Makefiles hand $(MAKEFLAGS) to their sub-makes as plain words.
# GNU make 4.3 (Ubuntu 24.04, Debian 12) writes the -w that "make -C" adds
# as a bare "w", which the sub-make then takes for a target and fails. So
# run make from inside the directory, without flags inherited from outside.
make_in() { # $1 = directory, then the make arguments
    local dir=$1; shift
    ( cd "$dir" && env -u MAKEFLAGS -u MFLAGS make "$@" )
}

# tclsh reading a script from stdin exits 0 even after an error, so these
# Tcl checks exit 1 themselves when something fails.
tcl_patchlevel() { # $1 = the tclsh to ask
    echo 'if {[catch {puts [info patchlevel]}]} {exit 1}' | "$1"
}
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
check_emacs() { # sets EMACS_VERSION, or stops
    command -v emacs >/dev/null || die "emacs not found. Install it: apt-get install emacs"
    EMACS_VERSION=$(emacs -Q --batch --eval '(princ emacs-version)' 2>>"$LOG") ||
        die "emacs is installed but does not run in batch mode"
    emacs_new_enough ||
        die "emacspeak needs Emacs 29.1 or newer, and $(command -v emacs) is Emacs $EMACS_VERSION"
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
[ -r /etc/os-release ] ||
    die "no /etc/os-release; this script is for Debian, Ubuntu or Linux Mint"
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu|linuxmint) ;;
    *) case " ${ID_LIKE:-} " in
           *" debian "*|*" ubuntu "*)
               echo "Warning: ${PRETTY_NAME:-this system} is not Debian, Ubuntu or Mint itself; trying anyway." ;;
           *) die "this script is for Debian, Ubuntu or Linux Mint, and this is ${PRETTY_NAME:-unknown}." ;;
       esac ;;
esac
# Mint and other relatives also name the release they are built on.
BASE=${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}}
case "$BASE" in
    trixie) BASE_NAME="Debian 13" ;;
    noble)  BASE_NAME="Ubuntu 24.04" ;;
    *)      BASE_NAME="" ;;
esac
if [ -z "$BASE_NAME" ]; then
    echo "Warning: tested on Debian 13 and Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}; trying anyway."
elif [ "${ID:-}" = debian ] || [ "${ID:-}" = ubuntu ]; then
    echo "${PRETTY_NAME:-$BASE_NAME}: supported."
else
    echo "${PRETTY_NAME:-This system} is built on $BASE_NAME: supported."
fi
case " ${ID:-} ${ID_LIKE:-} " in
    *" ubuntu "*) SOURCES_HINT="On Ubuntu and Mint they are in the universe \
repository. Turn it on with: add-apt-repository universe, then rerun this script." ;;
    *)            SOURCES_HINT="Check the apt sources in /etc/apt, then rerun this script." ;;
esac
: > "$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    log "Updating the package lists (apt-get update)"
    logged "apt-get update" apt_get update

    # Stop here, before installing anything, if a package is missing or
    # the Emacs would be too old for emacspeak.
    log "Checking that apt has the packages and a new enough Emacs"
    WANT=("${PACKAGES[@]}")
    command -v emacs >/dev/null || WANT+=(emacs)
    missing=""
    for p in "${WANT[@]}"; do
        [ -n "$(apt_candidate "$p")" ] || missing="$missing $p"
    done
    [ -z "$missing" ] || die "apt cannot find these packages:$missing. $SOURCES_HINT"
    echo "All ${#WANT[@]} packages are available."
    if command -v emacs >/dev/null; then
        check_emacs
        echo "Emacs $EMACS_VERSION is already installed: new enough."
    else
        EMACS_PACKAGE=$(apt_candidate emacs)
        EMACS_PACKAGE=${EMACS_PACKAGE#*:}         # drop the epoch, as in 1:30.1
        EMACS_PACKAGE=${EMACS_PACKAGE%%[-+~]*}    # keep 30.1 of 30.1+1-6
        if ! dpkg --compare-versions "$EMACS_PACKAGE" ge 29.1; then
            hint="Install Emacs 29.1 or newer another way, then rerun this script."
            [ "$BASE" != bookworm ] || hint="Debian 12 has a newer Emacs in \
bookworm-backports (see https://backports.debian.org/Instructions/). Install \
it with: apt-get install -t bookworm-backports emacs, then rerun this script."
            die "emacspeak needs Emacs 29.1 or newer, and apt here offers Emacs $EMACS_PACKAGE. $hint"
        fi
        echo "The emacs package is Emacs $EMACS_PACKAGE: new enough."
    fi

    log "Installing packages with apt-get (this can take a few minutes)"
    echo "Packages: ${PACKAGES[*]}"
    logged "apt-get install" apt_get install --no-install-recommends "${PACKAGES[@]}"
    if ! command -v emacs >/dev/null; then
        log "No Emacs found: installing the emacs package (Emacs $EMACS_PACKAGE)"
        logged "apt-get install emacs" apt_get install --no-install-recommends emacs
    fi
fi

log "Checking Emacs, Tcl 8.6 and TclX"
check_emacs
echo "Emacs $EMACS_VERSION: new enough."
for tool in git make g++; do
    command -v "$tool" >/dev/null || die "$tool not found. Install: ${PACKAGES[*]}"
done
[ -x "$TCLSH86" ] || die "$TCLSH86 not found. Install Tcl 8.6: apt-get install tcl8.6"
grep -q 'define TCL_VERSION[[:space:]]*"8.6"' "$TCL_INCLUDE/tcl.h" 2>/dev/null ||
    die "$TCL_INCLUDE/tcl.h is missing or is not Tcl 8.6. Install tcl8.6-dev."
[ -r /usr/include/espeak-ng/speak_lib.h ] ||
    die "espeak-ng headers not found. Install libespeak-ng-dev."
# The speech servers start with #!/usr/bin/tclsh. Debian's tcl package makes
# that Tcl 8.6; where it runs another Tcl, the servers get tclsh8.6 instead.
if [ -x /usr/bin/tclsh ] && DEFAULT_TCL=$(tcl_patchlevel /usr/bin/tclsh 2>>"$LOG"); then
    :
else
    DEFAULT_TCL=none
fi
case "$DEFAULT_TCL" in
    8.6.*) TCLSH=/usr/bin/tclsh; REWRITE=no
           echo "Default tclsh is Tcl $DEFAULT_TCL: the speech servers use it as it is." ;;
    none)  TCLSH=$TCLSH86; REWRITE=yes
           echo "No working /usr/bin/tclsh: the speech servers will use $TCLSH86." ;;
    *)     TCLSH=$TCLSH86; REWRITE=yes
           echo "Default tclsh is Tcl $DEFAULT_TCL, not 8.6: the speech servers will use $TCLSH86." ;;
esac
TCL_PATCHLEVEL=$(tcl_patchlevel "$TCLSH" 2>>"$LOG") || die "$TCLSH does not run. See $LOG"
TCLX=$(tclx_version 2>>"$LOG") ||
    die "TclX does not load in $TCLSH. Install it: apt-get install tclx8.4"
echo "Tcl 8.6 headers found; TclX $TCLX loads in $TCLSH."

# --------------------------------------------------------------------------
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's shebang changes first, so git sees unmodified files.
    for f in "$PREFIX"/servers/*; do
        if [ -f "$f" ] && [ "$(head -n 1 "$f")" = "#!$TCLSH86" ]; then
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
# The top-level "make espeak" hides a failed build, so run the sub-make.
# These values are the Makefile's own defaults, which match Debian's layout;
# they are spelled out so the build does not depend on them.
logged "building tclespeak.so" make_in "$PREFIX/servers/native-espeak" -B \
    TCL_INCLUDE="$TCL_INCLUDE" LIBS="-ltcl8.6 -lespeak-ng"
SO="$PREFIX/servers/native-espeak/tclespeak.so"
[ -f "$SO" ] || die "the build finished but $SO is missing"
echo "Built $SO"

if [ "$REWRITE" = yes ]; then
    log "Pointing the speech servers at $TCLSH86 (the default tclsh is not Tcl 8.6)"
else
    log "Checking which Tcl runs the speech servers"
fi
changed=""
kept=""
for f in "$PREFIX"/servers/*; do
    [ -f "$f" ] || continue
    first=$(head -n 1 "$f")
    case "$first" in
        '#!'*tclsh*)
            if [ "$REWRITE" = no ] && [ "$first" = "#!/usr/bin/tclsh" ]; then
                kept="$kept ${f##*/}"
            else
                sed -i "1s|.*|#!$TCLSH86|" "$f"; changed="$changed ${f##*/}"
            fi ;;
    esac
done
[ -n "$changed$kept" ] || die "no Tcl speech servers found in $PREFIX/servers"
[ -z "$kept" ] || echo "Unchanged, run by /usr/bin/tclsh:$kept"
[ -z "$changed" ] || echo "Changed to $TCLSH86:$changed"

log "Writing the launcher $LAUNCHER"
cat > "$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak, speaking through espeak-ng.
# Written by install-emacspeak-debian.sh. DTK_PROGRAM picks the speech server.
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
Speech server: espeak, run by $TCLSH (Tcl $TCL_PATCHLEVEL)
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
