#!/usr/bin/env bash
# install-emacspeak-macos.sh: emacspeak with OmniVox speech on macOS.
#
# OmniVox (https://github.com/robertmeta/omnivox) is an emacspeak speech
# server written in Rust, a drop-in replacement for SwiftMac. On macOS it
# speaks with the system voices through AVSpeechSynthesizer. This script
# installs OmniVox's prebuilt release (checksum verified) or builds it from
# source, clones and byte-compiles emacspeak, registers OmniVox as a speech
# server, and writes an emacspeak launcher.
#
# Run it as your normal user, never with sudo: Homebrew refuses to run as
# root, and everything goes into your home folder and Homebrew's folder.
# It runs with the bash 3.2 that macOS ships.
# For Linux, use the other installers in this folder.

set -euo pipefail

# OmniVox's documentation expects emacspeak in ~/.emacspeak, with its
# speech servers in ~/.emacspeak/servers, so that is the default here.
# emacspeak keeps your own files there too; git updates leave them alone.
PREFIX=$HOME/.emacspeak
REPO=https://github.com/tvraman/emacspeak.git
REF=master
SKIP_DEPS=no
RUN_TESTS=yes
OMNIVOX_ROUTE=prebuilt
OMNIVOX_VERSION=""
OMNIVOX_REPO=robertmeta/omnivox
# Used only when GitHub cannot be asked for the latest release and no
# OmniVox is installed yet: the release this script was written against.
OMNIVOX_FALLBACK=1.3.0
# Fully qualified, so Homebrew 6 trusts this one formula, not the whole tap.
EMACS_FORMULA=d12frosted/emacs-plus/emacs-plus@30
LOG=$HOME/Library/Logs/install-emacspeak-macos.log
MARKER="Written by install-emacspeak-macos.sh"

usage() {
    cat <<USAGE
Usage: bash install-emacspeak-macos.sh [options]

Installs emacspeak with OmniVox speech on macOS 13 or newer.
Run it as your normal user, not with sudo. It needs Homebrew.
Run it again later to update emacspeak and OmniVox.

Options:
  --prefix DIR           where emacspeak is cloned and built
                         (default $PREFIX)
  --repo URL             emacspeak git repository (default $REPO)
  --ref REF              branch or tag to build (default $REF)
  --omnivox-version VER  OmniVox release to install, such as 1.3.0
                         (default: the latest release)
  --omnivox-source       build OmniVox from source with cargo
                         instead of using the prebuilt release
  --skip-deps            do not run brew; you installed Emacs
                         (and cmake and Rust) yourself
  --no-test              skip the self-tests at the end
  --help                 show this help

Without Emacs 29.1 or newer, it installs $EMACS_FORMULA
with Homebrew. --omnivox-source also needs cmake and Rust, which it
installs with Homebrew if they are missing. Build output goes to
$LOG.
USAGE
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*"; }

# Run a noisy command with its output in $LOG. If it fails, show the end of
# the log, then the error, so the last line on screen names the problem.
# HINT, set by each section, says what to do about a failure there.
HINT=""
logged() {
    local what=$1; shift
    if ! "$@" >>"$LOG" 2>&1; then
        printf '\nLast lines of %s:\n' "$LOG" >&2
        tail -n 20 "$LOG" >&2
        die "$what failed. ${HINT:+$HINT }The full output is in $LOG"
    fi
}

# emacspeak's Makefile runs its sub-makes as "$(MAKE) $(MAKEFLAGS)", so any
# flag make puts into MAKEFLAGS (make -C adds -w) becomes a bogus target.
# So never use make -C or make options here: change into the folder in a
# subshell and run make with the inherited flag variables cleared.
make_in() { # $1 = folder, the rest = make arguments
    local dir=$1; shift
    (cd "$dir" && unset MAKEFLAGS MFLAGS MAKELEVEL && make "$@")
}

# macOS has no timeout command. Run a command with INPUT on its standard
# input, stop it after SECONDS, and return its exit status (143 if stopped).
# The watcher stops its own sleep when it is stopped, so nothing lingers.
limited() { # $1 = seconds, $2 = input, the rest = the command
    local secs=$1 input=$2 pid watcher rc=0
    shift 2
    "$@" <<<"$input" &
    pid=$!
    (
        sleep "$secs" & nap=$!
        trap 'kill "$nap"; exit 0' TERM
        wait "$nap" && kill "$pid"
    ) >/dev/null 2>&1 &
    watcher=$!
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    # Reap the stopped watcher quietly, or bash prints "Terminated".
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

emacs_new_enough() { # $1 = an emacs program
    "$1" -Q --batch --eval '(kill-emacs (if (version<= "29.1" emacs-version) 0 1))' \
        2>>"$LOG"
}
emacs_version() { # $1 = an emacs program
    "$1" -Q --batch --eval '(princ emacs-version)' 2>>"$LOG"
}

# Sets EMACS_BIN to the first Emacs 29.1 or newer: the one on PATH, then
# Homebrew's emacs-plus@30, which may be installed but not linked.
find_emacs() {
    local candidate
    EMACS_BIN=""
    for candidate in "$(command -v emacs || true)" \
                     "$BREW_PREFIX/opt/emacs-plus@30/bin/emacs"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ] &&
           emacs_new_enough "$candidate"; then
            EMACS_BIN=$candidate
            return 0
        fi
    done
    return 1
}

# cargo from rustup lives in ~/.cargo/bin, which a script's PATH may lack.
find_cargo() {
    if ! command -v cargo >/dev/null && [ -x "$HOME/.cargo/bin/cargo" ]; then
        PATH="$HOME/.cargo/bin:$PATH"
    fi
    command -v cargo >/dev/null && command -v rustc >/dev/null
}

valid_version() {
    case "$1" in
        *[!0-9A-Za-z.-]*) return 1 ;;
        [0-9]*.[0-9]*)    return 0 ;;
        *)                return 1 ;;
    esac
}

# Prints the latest OmniVox release, such as 1.3.0, from the GitHub API.
latest_omnivox_version() {
    curl -fsSL --retry 2 --max-time 30 \
        "https://api.github.com/repos/$OMNIVOX_REPO/releases/latest" 2>>"$LOG" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p'
}

# servers/.servers is part of emacspeak's git tree. M-x dtk-select-server
# offers the names listed there, and OmniVox's README asks for both names.
register_omnivox() {
    local name
    [ -f "$SERVERS_LIST" ] || die "$SERVERS_LIST is missing; is $PREFIX an emacspeak clone?"
    # Add a final newline if the file lacks one, so each name gets its own line.
    [ -z "$(tail -c 1 "$SERVERS_LIST")" ] || printf '\n' >>"$SERVERS_LIST"
    for name in omnivox log-omnivox; do
        grep -qx "$name" "$SERVERS_LIST" || printf '%s\n' "$name" >>"$SERVERS_LIST"
    done
}
# Takes this script's two lines out again, so git sees the file unchanged.
unregister_omnivox() {
    [ -f "$SERVERS_LIST" ] || return 0
    grep -qx -e omnivox -e log-omnivox "$SERVERS_LIST" || return 0
    grep -vx -e omnivox -e log-omnivox "$SERVERS_LIST" >"$SERVERS_LIST.new" || true
    mv -f "$SERVERS_LIST.new" "$SERVERS_LIST"
}

# Installs an omnivox binary and omnivox-voices.el, then records the version.
place_omnivox() { # $1 = omnivox binary, $2 = omnivox-voices.el
    local out
    mkdir -p "$OMNIVOX_DIR/elisp"
    cp "$2" "$OMNIVOX_DIR/elisp/omnivox-voices.el"
    # Copy, then rename over the old binary, so a running server keeps its file.
    cp "$1" "$PREFIX/servers/omnivox.new"
    chmod 0755 "$PREFIX/servers/omnivox.new"
    mv -f "$PREFIX/servers/omnivox.new" "$PREFIX/servers/omnivox"
    # OmniVox's README registers the same binary under the name log-omnivox.
    ln -sfn omnivox "$PREFIX/servers/log-omnivox"
    out=$(limited 30 "" "$PREFIX/servers/omnivox" --version 2>>"$LOG") ||
        die "$PREFIX/servers/omnivox does not run on this Mac. Rerun with \
--omnivox-source to build it here. See $LOG"
    printf '%s\n' "$WANT" >"$OMNIVOX_DIR/installed-version"
    echo "Installed $PREFIX/servers/omnivox ($out), and log-omnivox beside it."
}

install_prebuilt_omnivox() { # $1 = version
    local v=$1 base tarball sums dir want got
    base=https://github.com/$OMNIVOX_REPO/releases/download/v$v
    tarball=omnivox-$v-macos-$ARCH.tar.gz
    sums=$OMNIVOX_DIR/downloads/sha256sums-$v.txt
    dir=$OMNIVOX_DIR/release-$v-$ARCH
    mkdir -p "$OMNIVOX_DIR/downloads" "$dir"
    log "Downloading OmniVox $v for $ARCH_NAME ($tarball)"
    HINT="Check the internet connection. If release $v lacks this file, pick \
another with --omnivox-version, or use --omnivox-source."
    logged "downloading $base/$tarball" curl -fsSL --retry 2 \
        -o "$OMNIVOX_DIR/downloads/$tarball" "$base/$tarball"
    logged "downloading $base/sha256sums.txt" curl -fsSL --retry 2 \
        -o "$sums" "$base/sha256sums.txt"
    want=$(awk -v f="$tarball" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")
    [ -n "$want" ] || die "sha256sums.txt of OmniVox $v has no line for $tarball, \
so it cannot be checked. Pick a release with --omnivox-version, or use --omnivox-source."
    got=$(shasum -a 256 "$OMNIVOX_DIR/downloads/$tarball" | awk '{ print $1 }')
    [ "$got" = "$want" ] || die "checksum mismatch for $tarball: expected $want, \
got $got. The download is damaged or was changed. Run the script again; if it \
fails again, use --omnivox-source."
    echo "Checksum verified: SHA-256 $got"
    HINT="Run the script again to download it afresh, or use --omnivox-source."
    logged "unpacking $tarball" tar -xzf "$OMNIVOX_DIR/downloads/$tarball" -C "$dir"
    [ -f "$dir/omnivox" ] && [ -f "$dir/omnivox-voices.el" ] ||
        die "$tarball does not hold omnivox and omnivox-voices.el; the release \
layout may have changed. Try --omnivox-source."
    place_omnivox "$dir/omnivox" "$dir/omnivox-voices.el"
}

build_omnivox_from_source() { # $1 = version
    local v=$1 tag=v$1 src=$OMNIVOX_DIR/src
    HINT="Check the internet connection, and that OmniVox has a release $tag."
    if [ -d "$src/.git" ]; then
        log "Updating the OmniVox source in $src to $tag"
        logged "fetching OmniVox $tag" git -C "$src" fetch -q --depth 1 origin \
            "refs/tags/$tag:refs/tags/$tag"
        logged "checking out OmniVox $tag" git -C "$src" checkout -q "$tag"
    else
        log "Cloning OmniVox $tag into $src"
        logged "cloning OmniVox" git clone -q --depth 1 --branch "$tag" \
            "https://github.com/$OMNIVOX_REPO.git" "$src"
    fi
    log "Building OmniVox $v with cargo (a few minutes; it compiles espeak-ng too)"
    HINT="Update Rust (rustup update, or brew upgrade rust) and rerun, or leave \
out --omnivox-source to use the prebuilt release."
    logged "cargo build" cargo build --release --manifest-path "$src/Cargo.toml"
    place_omnivox "$src/target/release/omnivox" "$src/elisp/omnivox-voices.el"
}

need_value() { [ $# -ge 2 ] || die "$1 needs a value (try --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)          need_value "$@"; PREFIX=$2; shift ;;
        --repo)            need_value "$@"; REPO=$2; shift ;;
        --ref)             need_value "$@"; REF=$2; shift ;;
        --omnivox-version) need_value "$@"; OMNIVOX_VERSION=${2#v}; shift ;;
        --omnivox-source)  OMNIVOX_ROUTE=source ;;
        --skip-deps)       SKIP_DEPS=yes ;;
        --no-test)         RUN_TESTS=no ;;
        --help|-h)         usage; exit 0 ;;
        *)                 die "unknown option $1 (try --help)" ;;
    esac
    shift
done
[ -z "$OMNIVOX_VERSION" ] || valid_version "$OMNIVOX_VERSION" ||
    die "--omnivox-version needs a release number such as 1.3.0"
# macOS realpath has no -m, so make the prefix absolute by hand.
case "$PREFIX" in /*) ;; *) PREFIX=$PWD/$PREFIX ;; esac
while [ "$PREFIX" != / ] && [ "${PREFIX%/}" != "$PREFIX" ]; do PREFIX=${PREFIX%/}; done
case "$PREFIX" in
    *'"'*|*\\*) die "--prefix must not contain quotes or backslashes" ;;
esac
SERVERS_LIST=$PREFIX/servers/.servers
OMNIVOX_DIR=$PREFIX/omnivox
INIT=$PREFIX/omnivox-init.el

# --------------------------------------------------------------------------
log "Checking the system"
[ "$(uname -s)" = Darwin ] ||
    die "this script is for macOS. For Linux, use the other installers in this folder."
[ "$EUID" -ne 0 ] ||
    die "do not run this as root or with sudo. Run it as your normal user: bash $0"
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=${MACOS_VERSION%%.*}
case "$MACOS_MAJOR" in
    ''|*[!0-9]*) die "could not read the macOS version (sw_vers said: $MACOS_VERSION)" ;;
esac
[ "$MACOS_MAJOR" -ge 13 ] ||
    die "this needs macOS 13 or newer, and this is macOS $MACOS_VERSION"
# hw.optional.arm64 is 1 on Apple silicon, even in a shell under Rosetta.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
    ARCH=arm64; ARCH_NAME="Apple silicon"
else
    ARCH=x64; ARCH_NAME=Intel
fi
echo "macOS $MACOS_VERSION on $ARCH_NAME: supported."
xcode-select -p >/dev/null 2>&1 ||
    die "the Xcode Command Line Tools are missing; they provide git, make and \
the C compiler. Install them with: xcode-select --install, then rerun this script."
if ! BREW=$(command -v brew); then
    BREW=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$candidate" ]; then BREW=$candidate; break; fi
    done
fi
[ -n "$BREW" ] ||
    die "Homebrew is not installed. Install it by following https://brew.sh, then rerun this script."
BREW_PREFIX=$("$BREW" --prefix)
BREW_ON_PATH=yes
case ":$PATH:" in *":$BREW_PREFIX/bin:"*) ;; *) BREW_ON_PATH=no ;; esac
PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
# Homebrew's bin folder belongs to you and is on PATH for Homebrew users,
# so the launcher goes there and needs no sudo.
LAUNCHER=$BREW_PREFIX/bin/emacspeak
echo "Homebrew: $BREW_PREFIX"
mkdir -p "${LOG%/*}"
: >"$LOG"
echo "Build log: $LOG"

# --------------------------------------------------------------------------
if [ "$SKIP_DEPS" = no ]; then
    HINT="Run brew doctor, fix what it reports, then rerun this script."
    if ! find_emacs; then
        log "No Emacs 29.1 or newer found: installing $EMACS_FORMULA with Homebrew"
        echo "Homebrew compiles emacs-plus from source: about 30 minutes on a recent Mac."
        if [ "$ARCH" = x64 ]; then
            warn "Homebrew no longer has prebuilt packages for Intel Macs, so \
Emacs's libraries compile too, which can take hours."
        elif [ "$MACOS_MAJOR" -lt 15 ]; then
            warn "Homebrew no longer has prebuilt packages for macOS $MACOS_MAJOR, \
so Emacs's libraries compile too, which can take hours."
        fi
        echo "Progress goes to the build log. To follow it: tail -f $LOG"
        logged "brew install $EMACS_FORMULA" "$BREW" install "$EMACS_FORMULA"
    fi
    if [ "$OMNIVOX_ROUTE" = source ]; then
        if ! command -v cmake >/dev/null; then
            log "Installing cmake with Homebrew (OmniVox's source build needs it)"
            logged "brew install cmake" "$BREW" install cmake
        fi
        # Homebrew's rust formula installs without running a remote script.
        if ! find_cargo; then
            log "Installing Rust with Homebrew (OmniVox's source build needs it)"
            logged "brew install rust" "$BREW" install rust
        fi
    fi
fi

log "Checking Emacs and the build tools"
if ! find_emacs; then
    if command -v emacs >/dev/null; then
        die "emacspeak needs Emacs 29.1 or newer, and $(command -v emacs) is \
Emacs $(emacs_version emacs || echo unknown). Install a newer one: brew install $EMACS_FORMULA"
    fi
    die "emacs not found. Install it: brew install $EMACS_FORMULA, or rerun without --skip-deps"
fi
EMACS_VERSION=$(emacs_version "$EMACS_BIN") ||
    die "$EMACS_BIN is installed but does not run in batch mode. Reinstall \
that Emacs (for emacs-plus: brew reinstall emacs-plus@30), then rerun."
echo "Emacs $EMACS_VERSION: new enough. Using $EMACS_BIN"
# emacspeak's lisp/Makefile runs plain "emacs", so put this one first.
PATH="${EMACS_BIN%/*}:$PATH"
# Apple's make (GNU make 3.81) is enough: emacspeak's Makefiles use only
# pattern rules and $(shell ...), nothing from newer GNU make.
for tool in git make curl shasum tar; do
    command -v "$tool" >/dev/null ||
        die "$tool not found. Install the Xcode Command Line Tools: xcode-select --install"
done
if [ "$OMNIVOX_ROUTE" = source ]; then
    command -v cmake >/dev/null || die "cmake not found. Install it: brew install cmake"
    find_cargo ||
        die "Rust (cargo) not found. Install it from https://rustup.rs or with: brew install rust"
    RUSTC_VERSION=$(rustc --version | awk '{ print $2 }')
    rust_minor=${RUSTC_VERSION#1.}
    rust_minor=${rust_minor%%.*}
    case "$rust_minor" in ''|*[!0-9]*) rust_minor=0 ;; esac
    [ "$rust_minor" -ge 70 ] ||
        die "OmniVox needs Rust 1.70 or newer, and this is $RUSTC_VERSION. \
Update it: rustup update, or brew upgrade rust"
    echo "Rust $RUSTC_VERSION and cmake found."
fi

# --------------------------------------------------------------------------
OLD_HEAD=""
HINT="Check the internet connection and the --repo and --ref values. For an \
update, also undo your own changes in $PREFIX (git -C $PREFIX status)."
if [ -d "$PREFIX/.git" ]; then
    log "Updating emacspeak in $PREFIX from $REPO ($REF)"
    # Undo this script's change to servers/.servers first, so git sees an
    # unmodified file. The names are added back after the update.
    unregister_omnivox
    OLD_HEAD=$(git -C "$PREFIX" rev-parse HEAD)
    logged "updating the clone in $PREFIX" \
        git -C "$PREFIX" pull -q --ff-only "$REPO" "$REF"
    register_omnivox
elif [ -e "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ]; then
    die "$PREFIX exists but is not a git clone of emacspeak. Move it away or use --prefix."
else
    log "Cloning emacspeak ($REF) from $REPO into $PREFIX"
    logged "git clone" git clone -q --depth 1 --branch "$REF" "$REPO" "$PREFIX"
fi
echo "Emacspeak source: $(git -C "$PREFIX" log -1 --format='commit %h of %cd' --date=short)"

log "Configuring emacspeak (make config)"
HINT="The lines above name the Lisp file that failed. Make sure $EMACS_BIN \
starts, then rerun; if it still fails, ask on the emacspeak mailing list."
logged "make config" make_in "$PREFIX" config
# make config only writes emacspeak-loaddefs.el when it is missing, so
# rebuild it when the update brought new commits.
if [ -n "$OLD_HEAD" ] && [ "$OLD_HEAD" != "$(git -C "$PREFIX" rev-parse HEAD)" ]; then
    log "Regenerating emacspeak's autoloads for the new commits"
    logged "regenerating emacspeak-loaddefs.el" \
        make_in "$PREFIX/lisp" -B emacspeak-loaddefs.el
fi

log "Byte-compiling emacspeak's Lisp (make emacspeak, a few minutes)"
logged "make emacspeak" make_in "$PREFIX" emacspeak

# --------------------------------------------------------------------------
mkdir -p "$OMNIVOX_DIR"
INSTALLED=$(cat "$OMNIVOX_DIR/installed-version" 2>/dev/null || true)
log "Choosing the OmniVox release"
# Latest by default, so rerunning this script also updates OmniVox. The
# checksum file comes from the same release: it catches a damaged download.
if [ -n "$OMNIVOX_VERSION" ]; then
    echo "OmniVox $OMNIVOX_VERSION, as asked with --omnivox-version."
elif OMNIVOX_VERSION=$(latest_omnivox_version) && valid_version "$OMNIVOX_VERSION"; then
    echo "Latest OmniVox release: $OMNIVOX_VERSION"
elif [ -n "$INSTALLED" ]; then
    OMNIVOX_VERSION=${INSTALLED%% *}
    warn "could not ask GitHub for the latest OmniVox release; keeping $OMNIVOX_VERSION."
else
    OMNIVOX_VERSION=$OMNIVOX_FALLBACK
    warn "could not ask GitHub for the latest OmniVox release; using $OMNIVOX_VERSION."
fi
if [ "$OMNIVOX_ROUTE" = source ]; then
    WANT="$OMNIVOX_VERSION source"
    ROUTE_TEXT="built from source"
else
    WANT="$OMNIVOX_VERSION macos-$ARCH"
    ROUTE_TEXT="prebuilt for $ARCH_NAME, checksum verified"
fi
if [ "$INSTALLED" = "$WANT" ] && [ -x "$PREFIX/servers/omnivox" ] &&
   [ -f "$OMNIVOX_DIR/elisp/omnivox-voices.el" ]; then
    echo "OmniVox $OMNIVOX_VERSION ($ROUTE_TEXT) is already installed; keeping it."
elif [ "$OMNIVOX_ROUTE" = source ]; then
    build_omnivox_from_source "$OMNIVOX_VERSION"
else
    install_prebuilt_omnivox "$OMNIVOX_VERSION"
fi

log "Registering OmniVox in $SERVERS_LIST"
register_omnivox
echo "Listed: omnivox, log-omnivox."

log "Writing $INIT"
cat >"$INIT" <<INIT
;;; omnivox-init.el --- emacspeak with OmniVox speech  -*- lexical-binding: t; -*-
;; $MARKER, which rewrites it on every run.
;; Load it from your own init file, or copy these settings there.

;; Emacspeak's Lisp, then OmniVox's voice module, which loads before emacspeak.
(add-to-list 'load-path "$PREFIX/lisp")
(add-to-list 'load-path "$OMNIVOX_DIR/elisp")
(require 'omnivox-voices)

;; Optional: M-x customize-group RET omnivox RET lists every OmniVox setting.
;; (setq omnivox-voice-id "en-US:Samantha")
;; (setq omnivox-speech-rate 60)   ; 0 to 100, 50 is normal

;; OmniVox's advice: keep macOS accessibility prompts from interrupting speech.
(when (eq system-type 'darwin)
  (setq mac-ignore-accessibility t))
;; OmniVox plays the auditory icons itself, so its sound volume applies.
(setq emacspeak-play-program nil)
;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)

(setq dtk-program (or (getenv "DTK_PROGRAM") "omnivox"))
(load-file "$PREFIX/lisp/emacspeak-setup.el")
INIT
echo "Written."

log "Writing the launcher $LAUNCHER"
[ -w "${LAUNCHER%/*}" ] ||
    die "${LAUNCHER%/*} is not writable by you. Fix Homebrew's permissions (brew doctor), then rerun."
if [ -L "$LAUNCHER" ] || { [ -e "$LAUNCHER" ] && ! grep -q "$MARKER" "$LAUNCHER"; }; then
    die "$LAUNCHER exists and was not written by this script. Move it away, then rerun."
fi
cat >"$LAUNCHER" <<LAUNCHER
#!/bin/sh
# Console Emacs with emacspeak, speaking through OmniVox.
# $MARKER. DTK_PROGRAM picks the speech server.
# -q skips your own init file, so emacspeak always starts the same way.
export DTK_PROGRAM="\${DTK_PROGRAM:-omnivox}"
exec "$EMACS_BIN" -nw -q -l "$INIT" "\$@"
LAUNCHER
chmod 0755 "$LAUNCHER"
echo "Launcher written."

# --------------------------------------------------------------------------
# Self-tests. Only the last one needs a sound output device, and it is
# skipped when OmniVox finds none.
OMNIVOX=$PREFIX/servers/omnivox
# Speech synthesis needs your logged-in session on the Mac.
SPEECH_FIX="If you ran this over ssh, run it in Terminal on the Mac itself."
LOAD_CHECK='(kill-emacs (if (and (featurep (quote emacspeak))
                                 (featurep (quote omnivox-voices))
                                 (file-executable-p
                                  (expand-file-name "omnivox" emacspeak-servers-directory)))
                            0 1))'
if [ "$RUN_TESTS" = yes ]; then
    log "Self-test 1 of 7: OmniVox reports its version"
    OUT=$(limited 30 "" "$OMNIVOX" --version 2>>"$LOG") ||
        die "Self-test 1 failed: $OMNIVOX --version did not run. Rerun with \
--omnivox-source to build it here. See $LOG"
    case "$OUT" in
        "omnivox "*) echo "Pass: $OUT." ;;
        *) die "Self-test 1 failed: $OMNIVOX --version printed: $OUT. Rerun \
with --omnivox-source to build it here." ;;
    esac

    log "Self-test 2 of 7: OmniVox lists the system voices"
    OUT=$(limited 60 "" "$OMNIVOX" --list-voices 2>>"$LOG") ||
        die "Self-test 2 failed: $OMNIVOX --list-voices did not finish. $SPEECH_FIX See $LOG"
    printf '%s\n' "$OUT" >>"$LOG"
    VOICES=$(sed -n 's/^Found \([0-9][0-9]*\) voices.*/\1/p' <<<"$OUT")
    [ "${VOICES:-0}" -ge 1 ] ||
        die "Self-test 2 failed: OmniVox found no voices. Check System Settings, \
Accessibility, Spoken Content."
    echo "Pass: $VOICES voices."

    log "Self-test 3 of 7: OmniVox's own check synthesizes speech"
    echo "With a sound device, you may hear a tone and: Omnivox is ready."
    OUT=$(limited 120 "" "$OMNIVOX" --check 2>>"$LOG") ||
        die "Self-test 3 failed: $OMNIVOX --check did not finish. $SPEECH_FIX See $LOG"
    printf '%s\n' "$OUT" >>"$LOG"
    grep -q 'Status: OK - ' <<<"$OUT" ||
        die "Self-test 3 failed: OmniVox could not synthesize speech. $SPEECH_FIX \
Its report is in $LOG"
    if grep -q 'Audio device: OK' <<<"$OUT"; then
        SOUND=yes
        echo "Pass: speech synthesized, and a sound output device was found."
    else
        SOUND=no
        echo "Pass: speech synthesized. No sound output device was found."
    fi

    log "Self-test 4 of 7: Emacs is 29.1 or newer"
    emacs_new_enough "$EMACS_BIN" ||
        die "Self-test 4 failed: Emacs $EMACS_VERSION is too old. Install a \
newer one: brew install $EMACS_FORMULA"
    echo "Pass: Emacs $EMACS_VERSION."

    log "Self-test 5 of 7: Emacs loads the init file and finds OmniVox (no speech)"
    "$EMACS_BIN" -Q --batch -l "$INIT" --eval "$LOAD_CHECK" >>"$LOG" 2>&1 ||
        die "Self-test 5 failed: Emacs could not load $INIT, or emacspeak \
does not find $OMNIVOX. Rerun the script to rebuild both. See $LOG"
    echo "Pass: emacspeak and omnivox-voices load, and emacspeak finds the server."

    log "Self-test 6 of 7: OmniVox is registered and the launcher is in place"
    for name in omnivox log-omnivox; do
        grep -qx "$name" "$SERVERS_LIST" ||
            die "Self-test 6 failed: $SERVERS_LIST does not list $name. Rerun the script."
    done
    [ -x "$PREFIX/servers/log-omnivox" ] ||
        die "Self-test 6 failed: $PREFIX/servers/log-omnivox is missing. Rerun the script."
    [ -x "$LAUNCHER" ] || die "Self-test 6 failed: $LAUNCHER is missing. Rerun the script."
    echo "Pass: both names are listed, and the launcher is executable."

    log "Self-test 7 of 7: the OmniVox server starts the way Emacs starts it"
    if [ "$SOUND" = yes ]; then
        echo "You should hear: Omnivox version $OMNIVOX_VERSION."
        limited 60 version "$OMNIVOX" >>"$LOG" 2>&1 ||
            die "Self-test 7 failed: the server did not start or exit cleanly. \
Check the output device in System Settings, Sound, then rerun. See $LOG"
        echo "Pass: the server spoke its version and exited cleanly."
        TESTS="all 7 passed"
    else
        echo "Skipped: the server needs a sound output device to start, and \
OmniVox found none. Connect speakers or headphones, then rerun."
        TESTS="6 of 7 passed; test 7 skipped, no sound output device"
    fi
else
    TESTS="skipped (--no-test)"
fi

# --------------------------------------------------------------------------
log "Done: emacspeak is installed"
cat <<DONE
Self-tests: $TESTS
Emacspeak is in $PREFIX
Speech server: OmniVox $OMNIVOX_VERSION, $ROUTE_TEXT
OmniVox is in $PREFIX/servers
Emacs $EMACS_VERSION: $EMACS_BIN
Launcher: $LAUNCHER
Build log: $LOG

To start it, run this in Terminal:
  emacspeak

The launcher starts console Emacs without your own init file (-q),
and sets DTK_PROGRAM=omnivox, which picks the OmniVox server.
To load emacspeak from your own Emacs init file instead, put this
line at the very top of ~/.emacs or ~/.emacs.d/init.el:
  (load-file "$INIT")

If VoiceOver is on, you hear both it and emacspeak.
Command-F5 turns VoiceOver off and on.
To choose a voice in Emacs: M-x omnivox-select-voice
Known OmniVox issue: text after two semicolons may not be spoken.

To update emacspeak and OmniVox later, run this script again.
DONE
if [ "$BREW_ON_PATH" = no ]; then
    printf '%s\n' "" \
        "Homebrew is not on your PATH yet, so the emacspeak command is not found." \
        "Add Homebrew to your shell, then open a new Terminal window:" \
        "  echo 'eval \"\$($BREW shellenv)\"' >> ~/.zprofile"
fi
