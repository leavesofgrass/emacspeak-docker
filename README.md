# Emacspeak + software DECtalk in Docker

A Debian container that runs [emacspeak](https://github.com/tvraman/emacspeak)
with a working **software DECtalk** speech server — the classic Perfect Paul
voice, not espeak — with audio delivered to your Windows speakers.

How the pieces fit together:

- **DECtalk** is built from the community-preserved sources at
  [github.com/dectalk/dectalk](https://github.com/dectalk/dectalk) (`develop`
  branch), installed in the container at `/opt/dectalk` (libraries,
  dictionaries, the `say` command, and `DECtalk.conf`).
- **Emacspeak** (git master) lives at `/opt/emacspeak`. Its `dtk-soft` speech
  server is a Tcl script that loads `tcldtk.so`, a small C extension compiled
  against DECtalk's `libtts` — this is the part that always needed the
  "enough symlinking" ritual, and the Dockerfile now does it reproducibly.
- **Audio** leaves the container over the PulseAudio network protocol to a
  tiny PulseAudio server running on Windows
  ([pulseaudio-win32](https://github.com/pgaskin/pulseaudio-win32)), which
  plays it through your default sound device. Everything emacspeak plays —
  DECtalk speech, auditory icons (`paplay`), and tones (`sox`) — takes the
  same path.

## Quick start

All commands are run in PowerShell from this folder (`D:\emacspeak-docker`).

Step 1 — set up audio on Windows (one time). This downloads the ~9 MB
pulseaudio-win32 v5 release from GitHub, configures it to accept audio from
Docker, starts it, and registers it to start at logon:

```bash
powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1 -AutoStart
```

When Windows Firewall asks about `pulseaudio.exe`, allow it (private networks
is enough). Without the firewall approval the container's audio cannot reach
Windows.

Step 2 — build the image (10–20 minutes the first time):

```bash
docker compose build
```

Step 3 — verify the whole speech chain:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -Test
```

You should hear DECtalk speak twice, and the test prints a numbered
pass/fail report for each link in the chain.

Step 4 — run emacspeak:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1
```

That starts console Emacs with emacspeak loaded and talking through DECtalk.
`C-e` is the emacspeak prefix. Your files in `.\work` appear in the container
at `~/work`, and your home directory (customizations, history) persists in a
Docker volume across runs.

## Daily driving

| Task | Command |
|------|---------|
| Start emacspeak (Outloud, the default) | `powershell -File run.ps1` or `docker compose run --rm emacspeak` |
| Start emacspeak (DECtalk) | `powershell -File run.ps1 -Dectalk` |
| Speech smoke test | `powershell -File run.ps1 -Test` |
| Shell in the container | `powershell -File run.ps1 -Shell` |
| Install Outloud engine | copy Voxin archive to `.\work`, then `powershell -File run.ps1 -InstallOutloud` |
| Rebuild after upstream changes | `docker compose build --no-cache` |
| Stop the Windows audio server | `powershell -File scripts\setup-audio.ps1 -Stop` |

A few emacspeak keys as a refresher: `C-e l` speak the current line,
`C-e d r` set speech rate, `C-e d p` set punctuation mode; the full command
help is at `C-h C-e`. DECtalk inline commands work as they always did — try
`M-x dtk-add-cleanup-pattern`, or just evaluate
`(dtk-speak "[:nb] Betty says hello")`.

## The Outloud (IBM ViaVoice / Eloquence) server

The image also ships everything emacspeak needs for its `outloud` server —
the compiled `atcleci.so` glue, ALSA routed to PulseAudio, and 32-bit
runtime libraries for engine builds that need them. The one piece that
cannot be included is the engine itself: `libibmeci.so` is proprietary IBM
code, sold today as **Voxin** (about 15 EUR) at
[voxin.oralux.net](https://voxin.oralux.net). The old 32-bit ViaVoice RTK
rpms alone won't drive the 64-bit glue; Voxin is the supported route.

To install it (once — it lives in a Docker volume, surviving rebuilds and
`--rm`):

1. Copy your Voxin archive (e.g. `voxin-installer-3.x.tgz`) into `.\work`.
2. Run:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -InstallOutloud
```

3. Verify (step 8 of the smoke test exercises Outloud):

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -Test
```

4. Run emacspeak with the ViaVoice voice:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -Outloud
```

The installer understands the Voxin 3.x tree natively: it extracts the rfs
tarballs and the ViaVoice engine/voice archives into the `voxin` volume,
generates `eci.ini`, links `libibmeci.so` to the libvoxin shim, and writes
`/opt/oralux/outloud.env` (library path + `ECIINI`), which the launchers
source. The image carries `/opt/IBM` and `/var/opt/IBM` symlinks pointing
into the volume, because libvoxin probes those exact absolute paths for the
engine. Outloud is the default voice (`DTK_PROGRAM: outloud` in
`docker-compose.yml`); switch back to DECtalk per-session with
`run.ps1 -Dectalk`, or permanently by setting `DTK_PROGRAM: dtk-soft`.

Outloud troubleshooting, should it ever go quiet: from `run.ps1 -Shell`,
run `voxin-say -w /tmp/t.wav "hello"` — a non-empty wav means the engine
itself is fine (a zero-byte wav with exit 0 is libvoxin's way of saying it
could not find or start the engine). `touch ~/libvoxin.ok` before running
makes libvoxin write debug logs to `/tmp/libvoxin.log.<pid>`.

## Configuration knobs

- **Speech server**: `docker-compose.yml` sets `DTK_PROGRAM=outloud`
  (Eloquence) as the default; `run.ps1 -Dectalk` or
  `DTK_PROGRAM=dtk-soft` gives software DECtalk. The `log-dtk-soft` and
  `log-outloud` variants log the server protocol to a file for debugging.
- **Latency**: `PULSE_LATENCY_MSEC` in `docker-compose.yml`, default 30.
  Raise it if audio stutters; lower it if speech feels laggy.
- **Version pinning**: `docker compose build` accepts
  `--build-arg DECTALK_REF=<ref>` and `--build-arg EMACSPEAK_REF=<ref>`
  (tag, branch, or commit) if you want reproducible builds rather than
  tracking `develop`/`master`.
- **Audio endpoint**: `PULSE_SERVER` env var, default
  `tcp:host.docker.internal:4713`. If you ever move this setup to Linux or
  to docker-ce inside a WSL2 distro, set
  `PULSE_SERVER=unix:/mnt/wslg/PulseServer` and bind-mount `/mnt/wslg`
  instead — no Windows-side server needed there.

## Troubleshooting

Run the smoke test first; it isolates the failing link:

```bash
powershell -ExecutionPolicy Bypass -File run.ps1 -Test
```

- **Step 2 fails (no wav produced)** — DECtalk itself is broken in the
  image; rebuild, and check `build.log`. This should not happen on a
  successful build.
- **Step 3 fails (no PulseAudio server)** — the Windows side is the
  problem. Check that `pulseaudio.exe` is running (`Get-Process pulseaudio`),
  re-run `scripts\setup-audio.ps1`, and check the firewall: it must be
  allowed on the network profile of the WSL/Docker adapter. A quick manual
  check from PowerShell: `Test-NetConnection localhost -Port 4713`.
- **Steps pass but no sound is audible** — check the Windows default output
  device and the per-app volume mixer (pulseaudio shows up as its own app).
- **Speech is delayed or choppy** — tune `PULSE_LATENCY_MSEC` (see above).
- **Emacspeak starts silent** — inside the container run
  `test-speech`; also try `DTK_PROGRAM=log-dtk-soft emacspeak`, then read
  the log it names to see the server conversation.

## Beyond Docker: bare metal, and how all this actually works

[GUIDE.md](GUIDE.md) is the full write-up: the architecture of every layer
(emacspeak's server protocol, atcleci, libvoxin/voxind, DECtalk's conf
search), the anatomy of a Voxin archive, a step-by-step bare-metal install
with the reason for each step, the Docker-specific adaptations, and every
gotcha we hit while getting here.

[scripts/install-emacspeak-voxin.sh](scripts/install-emacspeak-voxin.sh)
automates the bare-metal path on a Debian-family system — tested on a fresh
Debian 13:

```bash
sudo ./install-emacspeak-voxin.sh /path/to/voxin-enu-v3.3rc4.tar.gz --with-dectalk
```

## What's in this folder

- `Dockerfile` — two stages: DECtalk built on Debian bookworm (older gcc is
  kinder to 1990s C), final image on Debian trixie with Emacs 30, Tcl/TclX,
  emacspeak from git, and the compiled `tcldtk.so`.
- `docker-compose.yml` — run configuration: audio env vars, `./work` bind
  mount, persistent home volume.
- `container/` — files baked into the image: the `emacspeak` launcher,
  `test-speech`, `install-outloud`, and the Emacs `init.el` that loads
  emacspeak.
- `scripts/setup-audio.ps1` — Windows-side PulseAudio install/start/stop.
- `run.ps1` — convenience launcher (`-Test`, `-Shell`).

## Making this repo public

The repository is set up so the licensed Voxin/ViaVoice payload can never
be committed by accident:

- `.gitignore` excludes everything in `work/` plus any file matching the
  Voxin archive patterns (`*voxin*.tar.*`, `*.txz`, `rfs_*`), anywhere in
  the tree.
- `.githooks/pre-commit` is a second line of defense: it refuses to commit
  payload-pattern files or anything over 5 MB (nothing legitimate in this
  repo is that large). Enable it once per clone with:

```bash
git config core.hooksPath .githooks
```

Because these protections existed before the first commit, the history is
clean by construction — nothing to scrub before publishing. Keep the Voxin
archive itself in a private repo, as you do now, and hand people the
`install-outloud` / `install-emacspeak-voxin.sh` flow to combine the
public recipe with their own licensed copy.

## Notes on the DECtalk sources

The DECtalk code was shared publicly by its original developer in 2015 and
is community-maintained at github.com/dectalk/dectalk; it has no formal
open-source license. Building and using it privately, as this setup does, is
the community norm, but don't publish the built image to a public registry.
Emacspeak is GPL-2.0+.
