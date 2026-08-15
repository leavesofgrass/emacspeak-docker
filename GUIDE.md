# Emacspeak with real speech: the complete guide

This document explains, step by step and with reasons, how to get emacspeak
talking with the two classic high-quality synthesizers — **Outloud** (IBM
ViaVoice / Eloquence, via Voxin) and **software DECtalk** — on a modern
Debian-family Linux. It covers both the bare-metal path (automated by
[scripts/install-emacspeak-voxin.sh](scripts/install-emacspeak-voxin.sh))
and the Docker path (this repository's Dockerfile), and documents every trap
we hit while building it. The goal is that this setup never has to be
reverse-engineered again.

## Why this has always been hard

Three separate eras of software have to cooperate:

1. **Emacspeak** (1995–present) talks to "speech servers": small Tcl
   scripts reading a simple command protocol on stdin. The servers load
   compiled glue (`.so` files) to reach an actual synthesizer.
2. **IBM ViaVoice TTS** (late 1990s) was only ever released for Linux as
   32-bit binaries, and its runtime was withdrawn from distribution.
   **Voxin** (oralux.net) licenses it today and wraps it so 64-bit programs
   can use it — via an architecture that is clever and almost entirely
   undocumented.
3. **DECtalk** (1984–2000s) survived as a community-preserved source dump
   that builds on modern Linux but with 1990s C that new compilers dislike,
   and with configuration conventions (dictionary paths, `DECtalk.conf`)
   that nobody wrote down in one place.

None of these pieces documents its assumptions about the others. This guide
does.

## The moving parts

**The emacspeak server protocol.** Emacs starts one speech server as a
child process (chosen by the `DTK_PROGRAM` environment variable, e.g.
`outloud` or `dtk-soft`) and writes commands to its stdin: `q {text}`
queues text, `d` dispatches the queue, `s` stops speech, and so on. Each
server is a Tcl script in `emacspeak/servers/`, and every one of them
requires the **TclX** extension (Debian package `tclx8.4`) for signal
handling and its command loop. You can drive a server by hand — this is
the single most useful debugging trick in this whole domain:

    printf 'q {hello world}\nd\n' | ./servers/outloud

**The Outloud stack, from Emacs down to your sound card:**

- `servers/outloud` (Tcl) loads `servers/linux-outloud/atcleci.so`.
- `atcleci.so` is C++ glue compiled from `atcleci.cpp`. It does
  `dlopen("libibmeci.so")` at load time — it does not link the engine, so
  it builds on any machine — and plays the returned PCM through **ALSA**
  (device from `ALSA_DEFAULT`, else `default`) at Eloquence's native
  11025 Hz mono.
- `libibmeci.so` is, on a Voxin system, a symlink to **`libvoxin.so.1`** —
  a 64-bit shim implementing IBM's ECI API. This is the fact that unlocks
  everything: *libvoxin is libibmeci*; Voxin's packages just create the
  alias.
- `libvoxin.so.1` spawns **`voxind`**, a 32-bit helper process, and proxies
  every ECI call to it over a pipe. voxind lives in
  `/opt/oralux/voxin/rfs32/usr/bin/voxind` and is built with a *relative*
  ELF interpreter (`./lib/ld-linux.so.2`): libvoxin chdirs into the
  `rfs32` directory before exec, so voxind uses the ancient 32-bit loader
  and libraries bundled in `rfs32` regardless of what your host has. No
  chroot, no namespaces — it works in unprivileged containers.
- voxind loads the **real** 32-bit engine: `/opt/IBM/ibmtts/lib/libibmeci.so`
  plus per-language synthesizers (`enu50.so` for US English) and voice
  data, configured by `/var/opt/IBM/ibmtts/cfg/eci.ini` (path conveyed by
  the `ECIINI` environment variable — 1990s ViaVoice lore that still
  applies).

**The DECtalk stack** is one layer simpler:

- `servers/dtk-soft` (Tcl) loads `servers/software-dtk/tcldtk.so`, C glue
  that links `libtts.so`/`libtts_us.so` directly (no dlopen).
- `libtts` comes from building github.com/dectalk/dectalk (**`develop`**
  branch — `master` is a raw historical dump). Its `make` installs
  everything into a `dist/` folder: `lib/` (one lib per language), `dic/`
  (pronunciation dictionaries), and the `say` demo binary. Audio goes
  through PulseAudio or ALSA, whichever it found at configure time.
- At runtime `libtts` locates `DECtalk.conf` (which tells it where the
  dictionaries live) by checking, in order: the running executable's
  directory, that directory's parent, the current working directory, and
  finally `<prefix>/DECtalk.conf` where the prefix is compiled in and
  defaults to `/opt/dectalk`. Since the "executable" is `tclsh` or
  `emacs`, only the last location is dependable: **put the conf at
  `/opt/dectalk/DECtalk.conf` with absolute dictionary paths.** Emacspeak
  ships a ready-made template at `servers/software-dtk/DECtalk.conf`.

## Anatomy of a Voxin 3.x archive

Your `voxin-enu-v3.x.tar.gz` unpacks to an installer tree. The parts
that matter (everything else is packaging for specific distros):

- `packages/all/rfs_<version>.<arch>.txz` — 64-bit Voxin runtime,
  rooted at `/opt/oralux/voxin`: `lib/libvoxin.so*` (the shim) and
  `bin/voxin-say` (a standalone CLI speaker — your best diagnostic tool).
- `packages/all/rfs_<version>.all.txz` — architecture-independent parts:
  `include/` (eci.h) and the whole `rfs32/` 32-bit world including voxind.
- `packages/all/voxin-viavoice-all_*.txz` — the real IBM engine:
  `opt/IBM/ibmtts/lib/libibmeci.so` (32-bit), `etc/*.ini` templates, tools.
- `packages/all/voxin-viavoice-<lang>_*.txz` — one per licensed language:
  the synthesizer (`enu50.so`), dictionaries, and `var/opt/IBM` voice data.
- `packages/deb|rpm|...` — distro glue. The deb contains **only symlinks
  and headers**: `/usr/lib/libibmeci.so -> /opt/oralux/voxin/lib/libvoxin.so.1`
  etc. We reproduce those links ourselves instead of using the deb.

## Bare-metal install, step by step

This is exactly what `scripts/install-emacspeak-voxin.sh` automates:

    sudo ./install-emacspeak-voxin.sh voxin-enu-v3.x.tar.gz --with-dectalk

(The Voxin archive is optional: `--with-dectalk` alone installs a
DECtalk-only system, no license required, and the launcher's default voice
follows what you installed. The script detects Debian, Arch, and Fedora
families from `/etc/os-release` and adapts: package manager, TclX built
from source where unpackaged (Arch, Fedora), a private Tcl 8.6 where the
distro ships Tcl 9 (Fedora), the `[multilib]` repository enabled for
Voxin's 32-bit engine (Arch), and the shim symlink placed in the family's
trusted libdir.)

1. **Packages.** `git make gcc g++ tcl tcl8.6 tcl8.6-dev tclx8.4
   libasound2-dev sox libsox-fmt-all pulseaudio-utils` plus, after
   `dpkg --add-architecture i386`, the 32-bit runtime `libc6:i386
   libstdc++6:i386` (belt-and-suspenders for voxind; its rfs32 world is
   mostly self-contained). `tclx8.4` is non-negotiable — every emacspeak
   server dies without TclX. Emacs must be **29.1 or newer** (Debian 13's
   Emacs 30 is fine; Debian 12's Emacs 28 is not — emacspeak master will
   not build there).
2. **Extract the Voxin rfs tarballs to `/`.** They create
   `/opt/oralux/voxin/{lib,bin,include,rfs32}`.
3. **Extract the ViaVoice tarballs to `/`.** They create
   `/opt/IBM/ibmtts/...` and `/var/opt/IBM/ibmtts/...`. These absolute
   locations are not optional: **libvoxin probes literally
   `/opt/IBM/ibmtts/lib/libibmeci.so`** to decide whether an engine is
   installed, and if the probe fails it reports *success with zero audio*
   (see gotcha 2 below).
4. **Generate `eci.ini`.** Concatenate the engine's `etc/all.ini` with
   `etc/<lang>.ini` for each language you have (a language is "present"
   when its `<lang>50.so` exists in `/opt/IBM/ibmtts/lib`), and write the
   result to `/var/opt/IBM/ibmtts/cfg/eci.ini`. Export
   `ECIINI=/var/opt/IBM/ibmtts/cfg/eci.ini` (the script drops this into
   `/etc/profile.d/voxin.sh` and the launcher).
5. **Wire the libraries.**
   `ln -sf /opt/oralux/voxin/lib/libvoxin.so.1 /usr/lib/libibmeci.so` —
   in `/usr/lib` specifically, because `dlopen` with a bare name searches
   the trusted system directories, and that's how `atcleci.so` loads the
   engine. Then `echo /opt/oralux/voxin/lib >
   /etc/ld.so.conf.d/voxin.conf && ldconfig` so that `voxin-say` (linked
   against `libvoxin.so.1` by soname) also resolves.
6. **Self-test before touching emacspeak:**
   `voxin-say -w /tmp/t.wav "hello"` must produce a non-empty wav. This
   needs no sound card and no emacspeak — it isolates the entire Voxin
   stack.
7. **Build emacspeak.** Clone github.com/tvraman/emacspeak, `make config
   && make emacspeak` (byte-compiles the lisp; runs in place, no install
   step), then `make -C servers/linux-outloud` to compile `atcleci.so`.
8. **Optional DECtalk.** Clone github.com/dectalk/dectalk (`develop`),
   `cd src && ./autogen.sh && ./configure && make -j`, copy `dist/` to
   `/opt/dectalk`, copy the C headers from `src/dapi/src/include/` to
   `/opt/dectalk/include/dtk/` (the dist omits them, and
   `tcldtk.c` includes `<dtk/ttsapi.h>`), register `/opt/dectalk/lib`
   with ldconfig, copy emacspeak's `DECtalk.conf` template to
   `/opt/dectalk/DECtalk.conf`, and build
   `servers/software-dtk/tcldtk.so` with `-I/opt/dectalk/include
   -L/opt/dectalk/lib`. Note the compiler generation problem: this code
   predates modern C rules, so on gcc 14+ configure with
   `CFLAGS="-O2 -fpermissive"` (or build on Debian 12 / in the Docker
   image, which uses bookworm's gcc 12 for this stage).
9. **Launch.** `emacspeak` (the installed launcher) = console Emacs with
   `DTK_PROGRAM=outloud`. For your own config, load
   `emacspeak-setup.el` first thing in `~/.emacs`.

## The Docker variant, and why it differs

The Dockerfile in this repository produces the same result with three
adaptations:

- **The engine lives in a volume, not the image.** Voxin is licensed
  software, and images get rebuilt and pushed around; a named volume
  (`voxin`, mounted at `/opt/oralux`) survives both. Because libvoxin
  insists on the absolute `/opt/IBM` and `/var/opt/IBM` paths, the image
  bakes symlinks from those paths into the volume
  (`/opt/IBM -> /opt/oralux/voxin/rfs32/opt/IBM`, likewise `/var/opt/IBM`),
  and `install-outloud` extracts the engine *into* the volume rather than
  onto `/`. An env file in the volume (`/opt/oralux/outloud.env`) carries
  `LD_LIBRARY_PATH` and `ECIINI`, sourced by the launcher — the volume
  equivalent of `ldconfig` + `profile.d`.
- **ALSA is routed to PulseAudio.** A container has no sound card. Outloud
  speaks ALSA, so `/etc/asound.conf` maps ALSA's `default` PCM to Pulse
  (`libasound2-plugins`), and everything — DECtalk, Outloud, auditory
  icons, sox tones — leaves the container as one PulseAudio stream to
  wherever `PULSE_SERVER` points.
- **Audio egress depends on the host.** On Windows (Docker Desktop, no
  WSL distro): a tiny PulseAudio server on the host
  ([pulseaudio-win32](https://github.com/pgaskin/pulseaudio-win32)) and
  `PULSE_SERVER=tcp:host.docker.internal:4713`. With docker-ce inside a
  WSL2 distro or on a Linux host: bind-mount the WSLg/desktop Pulse
  socket and use `PULSE_SERVER=unix:...` instead — lower latency, no
  extra server.

## The gotchas, so nobody hits them again

1. **The deb's symlinks are relative.** `/usr/lib/libibmeci.so` inside
   Voxin's deb points to `../../opt/oralux/voxin/lib/libvoxin.so.1`. Copy
   that symlink anywhere else and it silently dangles — and if you copy it
   *into* `/opt/oralux/voxin/lib/`, it dangles while shadowing the real
   library, and can clobber `voxin-say` the same way. Never copy the deb's
   links; recreate them.
2. **libvoxin fails silently.** If the `/opt/IBM` probe fails, `voxin-say`
   still exits 0 and writes a **zero-byte wav**; the emacspeak server just
   says nothing. A 0-byte wav from `voxin-say` therefore means exactly one
   thing: the engine tree isn't where libvoxin looks. (Debug logging:
   `touch ~/libvoxin.ok`, rerun, read `/tmp/libvoxin.log.<pid>` — the
   trigger file is checked in `$HOME`, not `/tmp`.)
3. **voxind's relative interpreter.** `file` shows interpreter
   `./lib/ld-linux.so.2` — that leading `./` is load-bearing. voxind only
   runs when its working directory is the `rfs32` root, which libvoxin
   arranges. Running it by hand from elsewhere produces confusing loader
   errors that have nothing to do with the real problem.
4. **DECtalk's conf search.** `libtts` searching relative to "the
   executable" means `tclsh`/`emacs`, not your shell. Every mysterious
   "DECtalk works in one directory but not another" report traces to this.
   `/opt/dectalk/DECtalk.conf` with absolute `dic` paths ends it.
5. **The dist has no headers.** DECtalk's build output omits the C
   headers that emacspeak's `tcldtk.c` needs as `<dtk/ttsapi.h>`; stage
   them from `src/dapi/src/include/` yourself.
6. **Old C, new compilers.** DECtalk under gcc 14 hits
   implicit-function-declaration errors (hard errors since gcc 14);
   `-fpermissive` or an older gcc fixes it. Emacspeak itself needs Emacs
   29.1+. The two constraints pull in opposite directions — which is why
   the Docker image builds DECtalk on Debian 12 and runs everything on
   Debian 13.
7. **TclX.** `package require Tclx` failing (missing `tclx8.4`) makes
   every server die instantly with no speech and little explanation.
   Check it first: `echo 'package require Tclx' | tclsh`.
8. **`dtk-soft` needs `EMACSPEAK_DIR` in the environment** (it builds the
   path to `tcldtk.so` from it); `outloud` locates its own files from its
   script path and doesn't. Inside Emacs this is handled — emacspeak
   setenvs it at startup — and the installed launcher exports it too, but
   when driving `dtk-soft` by hand at a shell, `export
   EMACSPEAK_DIR=/opt/emacspeak` first or it dies on line one.
9. **Tcl 9 breaks the whole stack.** Distros that moved `tcl` to 9.x
   (Fedora did) can't run stock emacspeak servers at all: TclX doesn't
   compile against Tcl 9 (`TCL_PARSE_PART1` is gone), `atcleci.cpp`
   doesn't either (the `CONST` macro changed), and Fedora's packaged
   tclx doesn't even load in its own tclsh 9. Since emacspeak launches
   servers through their `#!/usr/bin/tclsh` shebang, the fix is a private
   Tcl 8.6 (the installer builds one under `/opt/emacspeak-tcl`) with the
   server shebangs rewritten to point at it.
10. **tclsh lies about errors on stdin.** `echo 'package require Tclx' |
    tclsh` exits 0 even when the package is missing — errors on
    stdin-fed commands don't set the exit status. Any scripted probe
    must use an explicit `exit`:
    `echo 'if {[catch {package require Tclx}]} {exit 1}' | tclsh`.
11. **64-bit `dlopen` search paths differ by family.** Fedora's trusted
    libdir is `/usr/lib64`; Debian's and Arch's is `/usr/lib`. The
    `libibmeci.so` shim symlink has to land in the right one or Outloud
    silently fails to load the engine.

## Verifying an install, layer by layer

Work upward; the first failing layer is the problem:

1. Engine: `voxin-say -w /tmp/t.wav "hello"` → non-empty wav.
   DECtalk: `/opt/dectalk/say -fo /tmp/t.wav -a "hello"` → non-empty wav.
2. Audio device: `paplay /tmp/t.wav` (or `aplay` for the ALSA path
   Outloud uses) → audible.
3. Server: `printf 'q {test}\nd\n' | $EMACSPEAK_DIR/servers/outloud` →
   speaks. Same with `servers/dtk-soft`.
4. Emacs: `DTK_PROGRAM=outloud emacspeak` → talking editor. (`C-e t` for
   the time is a fine hello-world.)

## What ends up where

- `/opt/oralux/voxin` — Voxin: shim libs, voxin-say, rfs32 (32-bit world)
- `/opt/IBM/ibmtts` — ViaVoice engine + language synthesizers (bare metal;
  in Docker these are symlinks into the volume)
- `/var/opt/IBM/ibmtts/cfg/eci.ini` — generated engine config (`ECIINI`)
- `/usr/lib/libibmeci.so` — symlink to `libvoxin.so.1` (bare metal)
- `/opt/dectalk` — DECtalk: `lib/`, `dic/`, `say`, `DECtalk.conf`,
  staged `include/dtk/` headers
- `/opt/emacspeak` — emacspeak, run in place; compiled glue in
  `servers/linux-outloud/atcleci.so` and `servers/software-dtk/tcldtk.so`
- `/usr/local/bin/emacspeak` — launcher (console Emacs, Outloud default)

## Licensing

Emacspeak is GPL-2.0+. Voxin/ViaVoice is commercial: your archive, your
license — keep it out of public images and repos (the ignore rules and
pre-commit hook in this repository enforce exactly that). The DECtalk sources were shared publicly by their
original developer and community-preserved, but carry no formal license;
build and use privately, don't redistribute binaries.
