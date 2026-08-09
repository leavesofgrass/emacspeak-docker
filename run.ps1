# run.ps1 -- start the emacspeak container (Outloud/ViaVoice voice by default).
#
#   powershell -ExecutionPolicy Bypass -File run.ps1                 # emacspeak with Outloud
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Dectalk        # emacspeak with software DECtalk
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Test           # speech smoke test
#   powershell -ExecutionPolicy Bypass -File run.ps1 -Shell          # bash shell in the container
#   powershell -ExecutionPolicy Bypass -File run.ps1 -InstallOutloud # install Voxin archive from .\work

param(
    [switch]$Test,
    [switch]$Shell,
    [switch]$Dectalk,
    [switch]$Outloud,
    [switch]$InstallOutloud
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if ($InstallOutloud) {
    docker compose run --rm -u root emacspeak install-outloud
} elseif ($Test) {
    docker compose run --rm emacspeak test-speech
} elseif ($Shell) {
    docker compose run --rm emacspeak bash
} elseif ($Dectalk) {
    docker compose run --rm -e DTK_PROGRAM=dtk-soft emacspeak
} elseif ($Outloud) {
    docker compose run --rm -e DTK_PROGRAM=outloud emacspeak
} else {
    docker compose run --rm emacspeak
}
