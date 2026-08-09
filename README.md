# Emacspeak with real speech

Give [emacspeak](https://github.com/tvraman/emacspeak) — the complete audio
desktop for Emacs — a voice worth listening to. One script (or one Docker
container) sets up emacspeak with **IBM ViaVoice / Eloquence** ("Outloud",
via [Voxin](https://voxin.oralux.net)) and **software DECtalk**: the two
classic synthesizers many blind users grew up on, instead of espeak.

If you have a Debian-family Linux system, you are three commands away from
a talking Emacs. If you're on Windows or prefer containers, the Docker
route gives you the same thing. Either way, every step is documented — see
[GUIDE.md](GUIDE.md) for how all the pieces actually work.

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

## Quick start with Docker

Use this on Windows, or anywhere you'd rather keep the whole stack in a
container. The container holds emacspeak, DECtalk, and (after a one-time
step) your Voxin engine; audio streams to a PulseAudio server on the host.

On **Windows** (Docker Desktop with the WSL2 backend):

1. Set up host audio — downloads the small
   [pulseaudio-win32](https://github.com/pgaskin/pulseaudio-win32) server,
   starts it, and registers it to start at logon. Allow it through the
   firewall when Windows asks:

```bash
powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1 -AutoStart
```

2. Build the image (10–20 minutes the first time):

```bash
docker compose build
```

3. If you have Voxin: copy the archive into `.\work`, then install it into
   a persistent volume (survives rebuilds; never enters the image):

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -InstallOutloud
```

4. Test, then run:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -Test
```

```bash
powershell -ExecutionPolicy Bypass -File run.ps1
```

`run.ps1` starts emacspeak with Eloquence; `-Dectalk` switches voice,
`-Shell` gives a bash shell, `-Test` runs the speech smoke test. Your
files live in `.\work` (mounted at `~/work` in the container) and your
home directory persists in a volume.

On a **Linux host**, the same compose file works with your desktop's
PulseAudio/PipeWire socket instead of the Windows server — set
`PULSE_SERVER=unix:/run/user/1000/pulse/native` (or the WSLg socket
`unix:/mnt/wslg/PulseServer` under docker-ce in WSL2) and bind-mount the
socket path in `docker-compose.yml`.

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
- `run.ps1` — Windows convenience launcher
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
