# Emacspeak with real speech

Give [emacspeak](https://github.com/tvraman/emacspeak) — the complete audio
desktop for Emacs — a voice worth listening to. One script (or one Docker
container) sets up emacspeak with **IBM ViaVoice / Eloquence** ("Outloud",
via [Voxin](https://voxin.oralux.net)) and **software DECtalk**: the two
classic synthesizers many blind users grew up on, instead of espeak.

**Pick your path:**

- **Debian-family Linux** (Debian, Ubuntu, Mint...): run one script —
  see "Quick start on Linux" below. Fastest route.
- **Any other Linux** (Fedora, Arch, openSUSE...): same script with
  `--skip-deps` after installing the equivalents of a short package list,
  or use Docker. See the note at the end of the Linux section.
- **macOS or Windows**: use Docker — see "Quick start with Docker". The
  Voxin engine is Linux-only binary code, so on a Mac it runs happily
  *inside* the Linux container but can never run bare-metal. (Mac users
  wanting native speech without Docker should look at emacspeak's own
  `mac` and `swiftmac` servers upstream — different voices, no Voxin.)

Every step of all of this is documented — see [GUIDE.md](GUIDE.md) for
how the pieces actually work.

## Quick start on Linux (Debian, Ubuntu, and friends)

**What you need:**

- A Debian-family system whose Emacs is version 29.1 or newer — Debian 13
  and Ubuntu 24.04 or later are fine. (The installer checks and tells you
  if yours is too old.)
- For the Eloquence voice: your licensed Voxin archive, about 15 EUR from
  [voxin.oralux.net](https://voxin.oralux.net) — a file like
  `voxin-enu-v3.3rc4.tar.gz`. **No Voxin? Skip it.** DECtalk needs no
  license and sounds like 1985 in the best way.

**Install** (pick the line that matches what you have):

```bash
git clone https://github.com/leavesofgrass/emacspeak-docker
cd emacspeak-docker

# Both voices (Voxin archive + DECtalk):
sudo ./scripts/install-emacspeak-voxin.sh ~/voxin-enu-v3.3rc4.tar.gz --with-dectalk

# DECtalk only — free, no archive needed:
sudo ./scripts/install-emacspeak-voxin.sh --with-dectalk

# Eloquence only:
sudo ./scripts/install-emacspeak-voxin.sh ~/voxin-enu-v3.3rc4.tar.gz
```

The script narrates each step, self-tests the speech engines before it
finishes, and fails loudly at the exact step that broke — so if anything
goes wrong, the last message on screen is the problem statement.

**Run it:**

```bash
emacspeak
```

That's a talking console Emacs. `C-e` is the emacspeak prefix (`C-e t`
speaks the time; `C-h C-e` lists everything). The default voice is
Eloquence when Voxin is installed, DECtalk otherwise; switch per-session
with `DTK_PROGRAM=dtk-soft emacspeak` or `DTK_PROGRAM=outloud emacspeak`.

To load emacspeak inside your own Emacs configuration instead of the
launcher, put this at the very top of `~/.emacs`:

```
(setenv "DTK_PROGRAM" "outloud")
(load-file "/opt/emacspeak/lisp/emacspeak-setup.el")
```

**Not on a Debian-family distro?** The script's only Debian-specific part
is `apt-get`. Install your distro's equivalents of: Emacs 29+, git, gcc
and g++, make, Tcl 8.6 with headers, TclX, ALSA headers (alsa-lib devel),
sox, pulseaudio-utils, and 32-bit glibc/libstdc++ runtime (for Voxin's
engine process) — then rerun with `--skip-deps`:

```bash
sudo ./scripts/install-emacspeak-voxin.sh --skip-deps ~/voxin-enu-v3.3rc4.tar.gz --with-dectalk
```

Everything after the package step is distro-independent.

## Quick start with Docker (Windows, macOS, or any Linux)

The container holds emacspeak, DECtalk, and (after a one-time step) your
Voxin engine; audio streams to a PulseAudio server on the host. The
commands below use `./run.sh` on macOS/Linux — Windows users substitute
`powershell -ExecutionPolicy Bypass -File run.ps1` with the flag spelled
`-Test`, `-Dectalk`, `-InstallOutloud`, and so on.

**Step 1 — host audio** (the only platform-specific step):

- **Windows** (Docker Desktop, WSL2 backend): this downloads the small
  [pulseaudio-win32](https://github.com/pgaskin/pulseaudio-win32) server,
  starts it, and registers it to start at logon. Allow it through the
  firewall when Windows asks:

```bash
powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1 -AutoStart
```

- **macOS** (Docker Desktop): install PulseAudio with Homebrew and run it
  listening for the container:

```bash
brew install pulseaudio
```

```bash
pulseaudio --daemon --exit-idle-time=-1 --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1;172.16.0.0/12"
```

- **Linux host**: no extra server needed — hand the container your
  desktop's existing PulseAudio/PipeWire socket. In
  `docker-compose.yml`, uncomment the pulse-socket volume line and set
  `PULSE_SERVER=unix:/run/host-pulse/native` (both marked with comments
  in the file).

**Step 2 — build the image** (10–20 minutes the first time):

```bash
docker compose build
```

**Step 3 — if you have Voxin**: copy the archive into `./work`, then
install it into a persistent volume (survives rebuilds; never enters the
image):

```bash
./run.sh install-outloud
```

**Step 4 — test, then run:**

```bash
./run.sh test
```

```bash
./run.sh
```

Plain `./run.sh` starts emacspeak with Eloquence (or DECtalk if no Voxin
is installed); `./run.sh dectalk` switches voice, `./run.sh shell` gives
a bash shell in the container. Your files live in `./work` (mounted at
`~/work` inside), and your home directory persists in a volume.

## Verifying and troubleshooting

Test the layers from the bottom up; the first one that fails is the
problem:

1. **Engine**: `voxin-say -w /tmp/t.wav "hello"` and/or
   `/opt/dectalk/say -fo /tmp/t.wav -a "hello"` must write a non-empty
   wav. No sound card needed. A **zero-byte wav with exit 0** from
   voxin-say means libvoxin can't find the engine at `/opt/IBM` — see the
   gotcha list in [GUIDE.md](GUIDE.md).
2. **Audio device**: `paplay /tmp/t.wav` (or `aplay`) must be audible.
   In Docker on Windows: is `pulseaudio.exe` running, and allowed through
   the firewall?
3. **Speech server**: `export EMACSPEAK_DIR=/opt/emacspeak`, then
   `printf 'q {test}\nd\n' | /opt/emacspeak/servers/outloud` (or
   `servers/dtk-soft`) must speak.
4. **Emacs**: `emacspeak` must talk from the first message.

In the container, `test-speech` runs all of these as a numbered report
(`run.ps1 -Test` from Windows). If speech is delayed or choppy over the
Docker/Windows path, raise `PULSE_LATENCY_MSEC` in `docker-compose.yml`;
if it feels laggy, lower it.

## How it all works

[GUIDE.md](GUIDE.md) is the full write-up: the emacspeak speech-server
protocol, what atcleci/libvoxin/voxind actually do, why voxind is a
self-contained 32-bit world, DECtalk's configuration search order, the
anatomy of a Voxin archive, and every trap we hit so you don't have to.
If you've ever wondered why this setup defeated so many attempts over the
years — that document is the answer.

## Repository layout

- `scripts/install-emacspeak-voxin.sh` — bare-metal installer (see above)
- `scripts/setup-audio.ps1` — Windows host audio (PulseAudio) setup
- `Dockerfile`, `docker-compose.yml` — the container route
- `container/` — files baked into the image: launcher, `test-speech`,
  `install-outloud`, Emacs init
- `run.sh`, `run.ps1` — convenience launchers (POSIX and Windows)
- `GUIDE.md` — the deep dive
- `work/` — your files; also where Voxin archives go (gitignored)

## Licensing, and keeping the proprietary payload out

Emacspeak is GPL-2.0+. The Voxin/ViaVoice engine is commercial — **bring
your own licensed archive**; it is never part of this repository or any
image built from it. `.gitignore` excludes the payload patterns, and a
pre-commit hook (`git config core.hooksPath .githooks` once per clone)
blocks payload-like or oversized files as a second line of defense. The
DECtalk sources are community-preserved with no formal license: build and
use privately, don't redistribute binaries.

## License

The scripts, Dockerfile, and documentation in this repository are
GPL-2.0-or-later — the same license as
[Emacspeak](https://github.com/tvraman/emacspeak) itself. The full GNU
General Public License version 2 text is in [LICENSE](LICENSE); as with
Emacspeak, you may use this work under version 2 or, at your option,
any later version. What the scripts install keeps its own terms: Voxin
is commercially licensed, and the DECtalk sources carry the caveats
above.
