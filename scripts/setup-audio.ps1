# setup-audio.ps1 -- one-time audio setup for the emacspeak container.
#
# Downloads the portable pulseaudio-win32 build (v5, ~9 MB) from
# https://github.com/pgaskin/pulseaudio-win32 into %LOCALAPPDATA%\pulseaudio-win32,
# writes a config that accepts audio from Docker containers, and starts it.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1            # install + start
#   powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1 -AutoStart # also run at logon
#   powershell -ExecutionPolicy Bypass -File scripts\setup-audio.ps1 -Stop      # stop the server
#
# The first time it starts listening, Windows Firewall will ask whether to allow
# pulseaudio.exe -- say yes (private networks is enough). Docker traffic arrives
# from the WSL NAT (a 172.x address), which the config's auth-ip-acl permits.

param(
    [switch]$AutoStart,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$Root = Join-Path $env:LOCALAPPDATA "pulseaudio-win32"
$ZipUrl = "https://github.com/pgaskin/pulseaudio-win32/releases/download/v5/pulseaudio.zip"
$Zip = Join-Path $Root "pulseaudio.zip"
$TaskName = "PulseAudio (emacspeak container audio)"

function Get-PulseExe {
    $exe = Get-ChildItem -Path $Root -Recurse -Filter "pulseaudio.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $exe) { return $null }
    return $exe.FullName
}

if ($Stop) {
    Get-Process pulseaudio -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "PulseAudio stopped."
    exit 0
}

# --- 1. Download and extract (skipped if already present) --------------------
if ($null -eq (Get-PulseExe)) {
    New-Item -ItemType Directory -Force $Root | Out-Null
    Write-Host "Downloading pulseaudio-win32 v5 (about 9 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZipUrl -OutFile $Zip -UseBasicParsing
    Write-Host "Extracting..."
    Expand-Archive -Path $Zip -DestinationPath $Root -Force
    Remove-Item $Zip
} else {
    Write-Host "pulseaudio-win32 already present in $Root"
}

$PulseExe = Get-PulseExe
if ($null -eq $PulseExe) { throw "pulseaudio.exe not found after extraction; check $Root" }
Write-Host "Using $PulseExe"

# --- 2. Write our config -----------------------------------------------------
# module-waveout plays through the default Windows output device.
# module-native-protocol-tcp accepts clients; auth-ip-acl limits who may connect
# without a cookie: loopback plus the private ranges Docker/WSL NAT uses.
$ConfDir = Join-Path $Root "emacspeak-config"
New-Item -ItemType Directory -Force $ConfDir | Out-Null
$Pa = Join-Path $ConfDir "emacspeak.pa"
@"
load-module module-waveout sink_name=output source_name=input record=0
load-module module-native-protocol-tcp port=4713 listen=0.0.0.0 auth-ip-acl=127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16
"@ | Out-File -Encoding ascii $Pa

# --- 3. Start it -------------------------------------------------------------
$PulseArgs = "-n -F `"$Pa`" --exit-idle-time=-1"
Get-Process pulseaudio -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath $PulseExe -ArgumentList $PulseArgs -WindowStyle Hidden
Start-Sleep -Seconds 2
if (Get-Process pulseaudio -ErrorAction SilentlyContinue) {
    Write-Host "PulseAudio is running and listening on port 4713."
} else {
    throw "PulseAudio failed to start. Run manually to see errors: `"$PulseExe`" $PulseArgs"
}

# --- 4. Optional autostart at logon ------------------------------------------
if ($AutoStart) {
    $Action = New-ScheduledTaskAction -Execute $PulseExe -Argument $PulseArgs
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop } catch {}
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings | Out-Null
    Write-Host "Registered scheduled task '$TaskName' to start PulseAudio at logon."
}

Write-Host ""
Write-Host "If Windows Firewall pops up a prompt for pulseaudio.exe, allow it on private networks."
Write-Host "Now start the container:  powershell -File run.ps1   (or: docker compose run --rm emacspeak)"
