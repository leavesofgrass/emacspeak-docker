#!/bin/sh
# run.sh -- start the emacspeak container from a Linux or macOS host.
# (Windows users: run.ps1 is the same thing in PowerShell.)
#
#   ./run.sh                  emacspeak, default voice (Outloud)
#   ./run.sh dectalk          emacspeak with software DECtalk
#   ./run.sh outloud          emacspeak with Outloud (explicit)
#   ./run.sh test             speech smoke test
#   ./run.sh shell            bash shell in the container
#   ./run.sh install-outloud  install the Voxin archive placed in ./work

cd "$(dirname "$0")" || exit 1

case "${1:-}" in
    "")               exec docker compose run --rm emacspeak ;;
    dectalk)          exec docker compose run --rm -e DTK_PROGRAM=dtk-soft emacspeak ;;
    outloud)          exec docker compose run --rm -e DTK_PROGRAM=outloud emacspeak ;;
    test)             exec docker compose run --rm emacspeak test-speech ;;
    shell)            exec docker compose run --rm emacspeak bash ;;
    install-outloud)  exec docker compose run --rm -u root emacspeak install-outloud ;;
    *) echo "usage: $0 [dectalk|outloud|test|shell|install-outloud]" >&2; exit 1 ;;
esac
