<#
.SYNOPSIS
Installs emacspeak with OmniVox speech on Windows 10 or 11.

.DESCRIPTION
OmniVox (https://github.com/robertmeta/omnivox) is an emacspeak speech
server written in Rust. On Windows it speaks with the system voices
through the WinRT SpeechSynthesizer. This script installs OmniVox's
prebuilt release (checksum verified) or builds it from source, clones
emacspeak, generates its autoloads, byte-compiles it, registers OmniVox
as a speech server, and writes an Emacs init file and a launcher.

Run it as your normal user, in Windows PowerShell 5.1 or PowerShell 7:
  powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1
Run it again later to update emacspeak and OmniVox.

Without Emacs 29.1 or newer it installs GNU Emacs with winget, and Git
the same way if git is missing. Otherwise it changes nothing outside the
prefix folder: no PATH, no HOME, no shortcuts, unless you ask with
-AddToPath, -SetHome or -StartMenuShortcut. For Linux and macOS, use
the other installers in this folder.

.PARAMETER Prefix
Where emacspeak is cloned and built. Default: .emacspeak in the folder
named by HOME, or in your profile folder when HOME is not set.

.PARAMETER Repo
The emacspeak git repository.

.PARAMETER Ref
The branch or tag to build. Default: master.

.PARAMETER OmnivoxVersion
The OmniVox release to install, such as 1.3.0. Default: the latest.

.PARAMETER OmnivoxSource
Build OmniVox from source with cargo instead of using the prebuilt
release. Needs Rust, CMake, LLVM (libclang) and the Visual Studio C++
build tools, which you install yourself.

.PARAMETER EmacsPath
The emacs.exe to use, Emacs 29.1 or newer. A folder holding
bin\emacs.exe, such as an unpacked GNU Emacs zip, works too.

.PARAMETER SkipDeps
Do not run winget. You installed Emacs and Git yourself.

.PARAMETER NoCompile
Do not byte-compile emacspeak; it then runs from source and starts
more slowly.

.PARAMETER NoTest
Skip the self-tests at the end.

.PARAMETER StartMenuShortcut
Add an Emacspeak shortcut to your Start menu.

.PARAMETER SetHome
Set the HOME environment variable of your account to your profile
folder, as OmniVox's README recommends when you load emacspeak from
your own init file.

.PARAMETER AddToPath
Add the prefix folder to the PATH of your account, so the emacspeak
command works in any new Command Prompt or PowerShell window.

.PARAMETER Help
Show a short usage text.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install-emacspeak-windows.ps1 -SkipDeps -EmacsPath D:\emacs-30.2\bin\emacs.exe
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Prefix = '',
    [string]$Repo = 'https://github.com/tvraman/emacspeak.git',
    [string]$Ref = 'master',
    [string]$OmnivoxVersion = '',
    [switch]$OmnivoxSource,
    [string]$EmacsPath = '',
    [switch]$SkipDeps,
    [switch]$NoCompile,
    [switch]$NoTest,
    [switch]$StartMenuShortcut,
    [switch]$SetHome,
    [switch]$AddToPath,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Marker = 'Written by install-emacspeak-windows.ps1'
$OmnivoxRepo = 'robertmeta/omnivox'
# Used only when GitHub cannot be asked for the latest release and no
# OmniVox is installed yet: the release this script was written against.
$OmnivoxFallback = '1.3.0'
$EmacsWingetId = 'GNU.Emacs'
$GitWingetId = 'Git.Git'
$MinEmacs = '29.1'
$TestCount = 8
$LF = [string][char]10
$CRLF = [string][char]13 + [string][char]10
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# git must never wait for a password prompt that nobody sees.
$GitEnv = @{ GIT_TERMINAL_PROMPT = '0' }

# --------------------------------------------------------------------------
# Output and the log. Every line on screen also goes to the log. Until the
# prefix holds the emacspeak clone the log is kept in memory, because git
# clones only into an empty folder; it is written out once the clone exists.
$script:LogPath = $null
$script:LogBuffer = New-Object System.Text.StringBuilder
# Set by each section: what to do about a failure there.
$script:Hint = ''

function Add-Log([string]$Text) {
    if ($null -ne $script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, $Text, $Utf8NoBom)
    } else {
        [void]$script:LogBuffer.Append($Text)
    }
}

function Open-Log([string]$Path) {
    [IO.File]::WriteAllText($Path, $script:LogBuffer.ToString(), $Utf8NoBom)
    $script:LogPath = $Path
    [void]$script:LogBuffer.Clear()
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text"
    Add-Log ($CRLF + '==> ' + $Text + $CRLF)
}

function Write-Info([string]$Text) {
    Write-Host $Text
    Add-Log ($Text + $CRLF)
}

function Write-Warn([string]$Text) {
    Write-Info "Warning: $Text"
}

function Get-LogRef {
    if ($null -ne $script:LogPath) { return "The full output is in $script:LogPath" }
    return ''
}

# Shows the end of the log, so the lines just above the error explain it.
function Show-LogTail {
    if ($null -ne $script:LogPath) {
        $text = [IO.File]::ReadAllText($script:LogPath)
    } else {
        $text = $script:LogBuffer.ToString()
    }
    $lines = @([regex]::Split($text.TrimEnd(), '\r?\n') | Select-Object -Last 20)
    Write-Host ''
    Write-Host 'Last lines of the log:'
    foreach ($line in $lines) { Write-Host $line }
}

function Fail([string]$Text) {
    Write-Host "ERROR: $Text"
    Add-Log ('ERROR: ' + $Text + $CRLF)
    exit 1
}

# Anything not caught below ends here, as one plain error line.
trap {
    $where = $_.InvocationInfo.ScriptLineNumber
    $text = $_.Exception.Message
    Write-Host "ERROR: unexpected failure at line $where of the script: $text"
    Add-Log ("ERROR: unexpected failure at line $where of the script: $text" + $CRLF)
    if ($null -ne $script:LogPath) { Write-Host "The full output is in $script:LogPath" }
    exit 1
}

function Show-Usage([string]$DefaultPrefix) {
    $lines = @(
        'Usage: powershell -ExecutionPolicy Bypass -File install-emacspeak-windows.ps1 [options]',
        '',
        'Installs emacspeak with OmniVox speech on Windows 10 or 11.',
        'Run it as your normal user. Run it again later to update',
        'emacspeak and OmniVox.',
        '',
        'Options:',
        '  -Prefix DIR          where emacspeak is cloned and built',
        "                       (default $DefaultPrefix)",
        '  -Repo URL            emacspeak git repository',
        '  -Ref REF             branch or tag to build (default master)',
        '  -OmnivoxVersion VER  OmniVox release to install, such as 1.3.0',
        '                       (default: the latest release)',
        '  -OmnivoxSource       build OmniVox from source with cargo',
        '  -EmacsPath FILE      the emacs.exe to use, 29.1 or newer',
        '  -SkipDeps            do not run winget; you installed Emacs',
        '                       and Git yourself',
        '  -NoCompile           do not byte-compile; run from source',
        '  -NoTest              skip the self-tests at the end',
        '  -StartMenuShortcut   add Emacspeak to your Start menu',
        '  -SetHome             set HOME to your profile folder',
        '  -AddToPath           add the prefix to your PATH',
        '  -Help                show this help',
        '',
        "Without Emacs $MinEmacs or newer, it installs $EmacsWingetId with winget,",
        "and $GitWingetId if git is missing. Nothing else outside the prefix",
        'changes unless you ask with the last three switches.',
        'Get-Help on this script shows more about each option.'
    )
    foreach ($line in $lines) { Write-Host $line }
}

# --------------------------------------------------------------------------
# Running programs. PowerShell 5.1 mangles quotes in native arguments and
# turns native error output into exceptions, so programs run through
# System.Diagnostics.Process, with their output appended to the log.

# Quotes one argument the way Windows programs split their command line.
function ConvertTo-Argument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq [char]92) {
            $slashes++
        } elseif ($c -eq [char]34) {
            [void]$sb.Append([char]92, 2 * $slashes + 1)
            [void]$sb.Append([char]34)
            $slashes = 0
        } else {
            if ($slashes -gt 0) { [void]$sb.Append([char]92, $slashes) }
            $slashes = 0
            [void]$sb.Append($c)
        }
    }
    if ($slashes -gt 0) { [void]$sb.Append([char]92, 2 * $slashes) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Runs a program with its input closed (or given INPUT), stops it after
# SECONDS, and returns its exit status and output. Never throws.
function Invoke-Program {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$Seconds = 600,
        [string]$WorkingDirectory = '',
        [string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $quoted = @()
    foreach ($a in $Arguments) { $quoted += ConvertTo-Argument $a }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8NoBom
    $psi.StandardErrorEncoding = $Utf8NoBom
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($name in $Environment.Keys) {
        $psi.EnvironmentVariables[$name] = [string]$Environment[$name]
    }
    Add-Log ('> ' + $FilePath + ' ' + $psi.Arguments + $CRLF)
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Add-Log ('(could not start: ' + $_.Exception.Message + ')' + $CRLF)
        return [pscustomobject]@{ Started = $false; ExitCode = -1; TimedOut = $false
                                  Output = ''; ErrorOutput = $_.Exception.Message }
    }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    try {
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
    } catch {
        # The program exited before reading its input; its status tells.
    }
    $timedOut = -not $process.WaitForExit($Seconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        [void]$process.WaitForExit(10000)
    } else {
        $process.WaitForExit()
    }
    $out = ''
    $err = ''
    if ($outTask.Wait(10000)) { $out = $outTask.Result }
    if ($errTask.Wait(10000)) { $err = $errTask.Result }
    $code = -1
    if (-not $timedOut) { $code = $process.ExitCode }
    foreach ($text in @($out, $err)) {
        if ($text) {
            # OmniVox colors its log lines; screen readers read the codes aloud.
            $plain = [regex]::Replace($text, ([string][char]27) + '\[[0-9;]*[A-Za-z]', '')
            Add-Log $plain
            if (-not $plain.EndsWith($LF)) { Add-Log $CRLF }
        }
    }
    if ($timedOut) { Add-Log ("(stopped after $Seconds seconds)" + $CRLF) }
    Add-Log ("(exit status $code)" + $CRLF)
    return [pscustomobject]@{ Started = $true; ExitCode = $code; TimedOut = $timedOut
                              Output = $out; ErrorOutput = $err }
}

# Like Invoke-Program, but a failure stops the script with WHAT and the hint.
function Invoke-Logged {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$Seconds = 1800,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )
    $r = Invoke-Program -FilePath $FilePath -Arguments $Arguments -Seconds $Seconds `
        -WorkingDirectory $WorkingDirectory -Environment $Environment
    if (-not $r.Started) {
        Fail "$What failed: $FilePath did not start ($($r.ErrorOutput)). $script:Hint"
    }
    if ($r.TimedOut) {
        Show-LogTail
        Fail "$What did not finish within $Seconds seconds. $script:Hint $(Get-LogRef)"
    }
    if ($r.ExitCode -ne 0) {
        Show-LogTail
        Fail "$What failed (exit status $($r.ExitCode)). $script:Hint $(Get-LogRef)"
    }
    return $r
}

# --------------------------------------------------------------------------
# Finding Emacs and git.

function Get-EmacsVersion([string]$Exe) {
    $r = Invoke-Program -FilePath $Exe -Arguments @('-Q', '--batch', '--eval', '(princ emacs-version)') -Seconds 120
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) { return $null }
    $v = $r.Output.Trim()
    if ($v -match '^[0-9]+(\.[0-9]+)+$') { return $v }
    return $null
}

function Test-NewEnough([string]$Version) {
    return ([version]$Version) -ge ([version]$MinEmacs)
}

# Turns a file or folder given with -EmacsPath into the emacs.exe it means.
function Resolve-EmacsExe([string]$Path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($c in @((Join-Path $full 'bin\emacs.exe'), (Join-Path $full 'emacs.exe'))) {
            if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
        }
        return $null
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ((Split-Path -Leaf $full) -ieq 'runemacs.exe') {
            $full = Join-Path (Split-Path -Parent $full) 'emacs.exe'
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        }
        return $full
    }
    return $null
}

# Every emacs.exe on PATH or in the usual install folders: the GNU
# installer (and winget, which runs it), Scoop and Chocolatey.
function Get-EmacsCandidates {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-Command -Name 'emacs.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $found.Add($c.Source)
    }
    $roots = @()
    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $roots += (Join-Path $base 'Emacs')
        $roots += (Join-Path $base 'Programs\Emacs')
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $found.Add((Join-Path $root 'bin\emacs.exe'))
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $found.Add((Join-Path $d.FullName 'bin\emacs.exe'))
        }
    }
    if ($env:LOCALAPPDATA) {
        $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $packages -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'GNU.Emacs*' -ErrorAction SilentlyContinue)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter 'emacs.exe' -ErrorAction SilentlyContinue)) {
                    $found.Add($f.FullName)
                }
            }
        }
    }
    if ($env:USERPROFILE) { $found.Add((Join-Path $env:USERPROFILE 'scoop\apps\emacs\current\bin\emacs.exe')) }
    if ($env:ProgramData) { $found.Add((Join-Path $env:ProgramData 'chocolatey\lib\emacs\tools\emacs\bin\emacs.exe')) }
    $seen = @{}
    $result = @()
    foreach ($p in $found) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += $p
    }
    return , $result
}

# Returns the newest Emacs 29.1 or newer as @{ Path; Version }, or $null.
# Older ones are reported, so a failure can name them.
function Find-Emacs {
    $best = $null
    foreach ($exe in (Get-EmacsCandidates)) {
        $v = Get-EmacsVersion $exe
        if ($null -eq $v) {
            Write-Info "Skipping $exe : it does not run in batch mode."
            continue
        }
        if (-not (Test-NewEnough $v)) {
            Write-Info "Skipping Emacs $v at $exe : emacspeak needs $MinEmacs or newer."
            continue
        }
        if ($null -eq $best -or ([version]$v) -gt ([version]$best.Version)) {
            $best = @{ Path = $exe; Version = $v }
        }
    }
    return $best
}

function Find-Git {
    $c = @(Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) { return $c[0].Source }
    $places = @()
    if ($env:ProgramFiles) { $places += (Join-Path $env:ProgramFiles 'Git\cmd\git.exe') }
    if ($env:LOCALAPPDATA) { $places += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe') }
    foreach ($p in $places) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Install-WithWinget([string]$Id, [string]$Name) {
    $winget = @(Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($winget.Count -eq 0) {
        Fail ("winget is not available, so $Name cannot be installed for you. Install " +
              'App Installer from the Microsoft Store (it provides winget), or install ' +
              "$Name yourself, then rerun this script (with -SkipDeps if you like).")
    }
    Write-Info "Windows may ask for permission to install $Name (an elevation prompt). Answer Yes."
    Write-Info 'Progress goes to the log; this can take several minutes.'
    $r = Invoke-Program -FilePath $winget[0].Source -Seconds 2400 -Arguments @(
        'install', '--exact', '--id', $Id,
        '--accept-source-agreements', '--accept-package-agreements')
    return $r
}

# The machine's own architecture, also from a 32-bit or emulated shell.
function Get-NativeArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $reg = (Get-ItemProperty -LiteralPath $key -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
        if ($reg) { $arch = $reg }
    } catch {
        # Keep the value from the environment.
    }
    return $arch
}

function ConvertTo-LispPath([string]$Path) {
    return $Path.Replace([string][char]92, '/')
}

# --------------------------------------------------------------------------
# servers\.servers is part of emacspeak's git tree. M-x dtk-select-server
# offers the names listed there, and OmniVox's README asks for both names.
# The file keeps its own line endings, so git sees only the two new lines.

function Get-NewlineOf([string]$Text) {
    if ($Text.Contains($CRLF)) { return $CRLF }
    return $LF
}

function Get-ServersNames([string]$Text) {
    return @([regex]::Split($Text, '\r?\n') | ForEach-Object { $_.Trim() })
}

function Register-Omnivox {
    if (-not (Test-Path -LiteralPath $ServersList -PathType Leaf)) {
        Fail "$ServersList is missing; is $PrefixPath an emacspeak clone? Move it away or use -Prefix."
    }
    $text = [IO.File]::ReadAllText($ServersList)
    $nl = Get-NewlineOf $text
    $names = Get-ServersNames $text
    $add = ''
    if ($text.Length -gt 0 -and -not $text.EndsWith($LF)) { $add = $nl }
    foreach ($name in @('omnivox', 'log-omnivox')) {
        if ($names -notcontains $name) { $add += $name + $nl }
    }
    if ($add.Trim()) { [IO.File]::AppendAllText($ServersList, $add, $Utf8NoBom) }
}

# Takes this script's two lines out again, so git sees the file unchanged.
function Unregister-Omnivox {
    if (-not (Test-Path -LiteralPath $ServersList -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($ServersList)
    $nl = Get-NewlineOf $text
    $endsWithNewline = $text.EndsWith($LF)
    $lines = @([regex]::Split($text, '\r?\n'))
    if ($endsWithNewline) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    $kept = @($lines | Where-Object { @('omnivox', 'log-omnivox') -notcontains $_.Trim() })
    if ($kept.Count -eq $lines.Count) { return }
    $new = $kept -join $nl
    if ($endsWithNewline -and $kept.Count -gt 0) { $new += $nl }
    [IO.File]::WriteAllText($ServersList, $new, $Utf8NoBom)
}

# --------------------------------------------------------------------------
# OmniVox.

function Test-ValidVersion([string]$Version) {
    return $Version -match '^[0-9]+\.[0-9]+[0-9A-Za-z.-]*$'
}

# Prints the latest OmniVox release, such as 1.3.0, from the GitHub API.
function Get-LatestOmnivoxVersion {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$OmnivoxRepo/releases/latest" `
            -UseBasicParsing -TimeoutSec 30
        $tag = $release.PSObject.Properties['tag_name']
        if ($null -eq $tag) { return $null }
        $v = ([string]$tag.Value).TrimStart('v')
        if (Test-ValidVersion $v) { return $v }
    } catch {
        Add-Log ('GitHub API: ' + $_.Exception.Message + $CRLF)
    }
    return $null
}

# Downloads URL to PATH unless an earlier run already did. The download goes
# to a .part file first, so an interrupted one is never taken as complete.
function Save-Download([string]$Url, [string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Info "Already downloaded: $(Split-Path -Leaf $Path)"
        return
    }
    $part = $Path + '.part'
    Add-Log ("Downloading $Url" + $CRLF)
    try {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 600
    } catch {
        Add-Log ($_.Exception.Message + $CRLF)
        Fail "could not download $Url ($($_.Exception.Message)). $script:Hint"
    }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

# Copies omnivox.exe and omnivox-voices.el into place, then records the version.
function Install-OmnivoxFiles([string]$Exe, [string]$El) {
    $elispDir = Join-Path $OmnivoxDir 'elisp'
    New-Item -ItemType Directory -Force -Path $elispDir | Out-Null
    try {
        Copy-Item -LiteralPath $El -Destination (Join-Path $elispDir 'omnivox-voices.el') -Force
        Copy-Item -LiteralPath $Exe -Destination $OmnivoxExe -Force
        # OmniVox's README registers the same binary under the name log-omnivox.
        # Windows links need administrator rights, so this is a copy.
        Copy-Item -LiteralPath $Exe -Destination $LogOmnivoxExe -Force
    } catch {
        Fail ("could not copy OmniVox into $PrefixPath\servers ($($_.Exception.Message)). " +
              'If emacspeak is running, quit Emacs, then rerun this script.')
    }
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--version') -Seconds 30
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Fail "$OmnivoxExe does not run on this computer. Rerun with -OmnivoxSource to build it here. $(Get-LogRef)"
    }
    [IO.File]::WriteAllText($InstalledFile, $script:Want + $CRLF, $Utf8NoBom)
    Write-Info "Installed $OmnivoxExe ($($r.Output.Trim())), and log-omnivox.exe beside it."
}

function Install-PrebuiltOmnivox([string]$Version) {
    $base = "https://github.com/$OmnivoxRepo/releases/download/v$Version"
    $zipName = "omnivox-$Version-windows-$Arch.zip"
    $downloads = Join-Path $OmnivoxDir 'downloads'
    $zip = Join-Path $downloads $zipName
    $sums = Join-Path $downloads "sha256sums-$Version.txt"
    $dir = Join-Path $OmnivoxDir "release-$Version-$Arch"
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    Write-Step "Downloading OmniVox $Version for $Arch ($zipName)"
    $script:Hint = ("Check the internet connection. If release $Version lacks this file, " +
                    'pick another with -OmnivoxVersion, or use -OmnivoxSource.')
    Save-Download "$base/$zipName" $zip
    Save-Download "$base/sha256sums.txt" $sums
    # PowerShell names ignore case, so these must not be called $want:
    # that would hide the script's $Want from Install-OmnivoxFiles.
    $expectedHash = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        $parts = @($line.Trim() -split '\s+', 2)
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $zipName) {
            $expectedHash = $parts[0].ToLowerInvariant()
            break
        }
    }
    if ($null -eq $expectedHash) {
        Fail ("sha256sums.txt of OmniVox $Version has no line for $zipName, so it cannot " +
              'be checked. Pick a release with -OmnivoxVersion, or use -OmnivoxSource.')
    }
    $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        # Set both files aside, so the next run downloads them afresh.
        foreach ($f in @($zip, $sums)) { Move-Item -LiteralPath $f -Destination ($f + '.bad') -Force }
        Fail ("checksum mismatch for ${zipName}: expected $expectedHash, got $actualHash. The " +
              "download is damaged or was changed; both files were set aside as .bad in " +
              "$downloads. Run the script again to download them afresh; if it fails again, " +
              'use -OmnivoxSource.')
    }
    Write-Info "Checksum verified: SHA-256 $actualHash"
    $script:Hint = 'Run the script again, or use -OmnivoxSource.'
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    } catch {
        Fail "could not unpack $zipName ($($_.Exception.Message)). $script:Hint"
    }
    $exe = Join-Path $dir 'omnivox.exe'
    $el = Join-Path $dir 'omnivox-voices.el'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $el -PathType Leaf)) {
        Fail ("$zipName does not hold omnivox.exe and omnivox-voices.el; the release layout " +
              'may have changed. Try -OmnivoxSource.')
    }
    Install-OmnivoxFiles $exe $el
}

# Rust's tools, CMake and libclang for OmniVox's source build, or a list of
# what is missing. Nothing is installed: on Windows these need the Visual
# Studio C++ build tools, which this script leaves to you.
function Find-SourceTools {
    $tools = @{ Cargo = $null; Rustc = $null; CMake = $null; LibClang = $null; Missing = @() }
    $cargo = @(Get-Command -Name 'cargo.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cargo.Count -gt 0) {
        $tools.Cargo = $cargo[0].Source
    } elseif ($env:USERPROFILE -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))) {
        $tools.Cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    }
    if ($tools.Cargo) {
        $rustc = Join-Path (Split-Path -Parent $tools.Cargo) 'rustc.exe'
        if (Test-Path -LiteralPath $rustc -PathType Leaf) { $tools.Rustc = $rustc }
    }
    if (-not $tools.Rustc) { $tools.Missing += 'Rust (cargo and rustc), from https://rustup.rs' }
    $cmake = @(Get-Command -Name 'cmake.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmake.Count -gt 0) {
        $tools.CMake = $cmake[0].Source
    } elseif ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'))) {
        $tools.CMake = Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe'
    } else {
        $tools.Missing += 'CMake, from https://cmake.org'
    }
    $clangDirs = @()
    if ($env:LIBCLANG_PATH) { $clangDirs += $env:LIBCLANG_PATH }
    if ($env:ProgramFiles) { $clangDirs += (Join-Path $env:ProgramFiles 'LLVM\bin') }
    foreach ($d in $clangDirs) {
        if (Test-Path -LiteralPath (Join-Path $d 'libclang.dll') -PathType Leaf) { $tools.LibClang = $d; break }
    }
    if (-not $tools.LibClang) {
        $tools.Missing += 'LLVM, for libclang.dll (https://github.com/llvm/llvm-project/releases), or set LIBCLANG_PATH'
    }
    return $tools
}

function Build-OmnivoxFromSource([string]$Version) {
    $tag = "v$Version"
    $src = Join-Path $OmnivoxDir 'src'
    $script:Hint = "Check the internet connection, and that OmniVox has a release $tag."
    if (Test-Path -LiteralPath (Join-Path $src '.git')) {
        Write-Step "Updating the OmniVox source in $src to $tag"
        Invoke-Logged -What "fetching OmniVox $tag" -FilePath $GitExe -Environment $GitEnv -Arguments @(
            '-C', $src, 'fetch', '-q', '--depth', '1', 'origin', "refs/tags/${tag}:refs/tags/$tag") | Out-Null
        Invoke-Logged -What "checking out OmniVox $tag" -FilePath $GitExe -Environment $GitEnv -Arguments @(
            '-C', $src, 'checkout', '-q', $tag) | Out-Null
    } else {
        Write-Step "Cloning OmniVox $tag into $src"
        Invoke-Logged -What 'cloning OmniVox' -FilePath $GitExe -Environment $GitEnv -Arguments @(
            'clone', '-q', '--depth', '1', '--branch', $tag, "https://github.com/$OmnivoxRepo.git", $src) | Out-Null
    }
    Write-Step "Building OmniVox $Version with cargo (several minutes; it compiles espeak-ng too)"
    $script:Hint = ('Update Rust (rustup update), make sure the Visual Studio C++ build tools ' +
                    'are installed, and rerun; or leave out -OmnivoxSource to use the prebuilt release.')
    $path = (Split-Path -Parent $SourceTools.Cargo) + ';' + (Split-Path -Parent $SourceTools.CMake) + ';' + $env:PATH
    $buildEnv = @{ PATH = $path; LIBCLANG_PATH = $SourceTools.LibClang }
    Invoke-Logged -What 'cargo build' -FilePath $SourceTools.Cargo -Seconds 5400 -Environment $buildEnv -Arguments @(
        'build', '--release', '--manifest-path', (Join-Path $src 'Cargo.toml')) | Out-Null
    Install-OmnivoxFiles (Join-Path $src 'target\release\omnivox.exe') (Join-Path $src 'elisp\omnivox-voices.el')
}

# --------------------------------------------------------------------------
# emacspeak's Lisp. make is usually missing on Windows, and make config
# stops at its chmod, so this does what lisp/Makefile does: generate the
# autoloads, then byte-compile each file in its own Emacs, in the order of
# the Makefile's OBJECTS list, with the Makefile's own Emacs options.

$EmacsBatch = @('-batch', '-q', '-no-site-file', '-f', 'package-initialize', '--eval',
                '(setq file-name-handler-alist nil gc-cons-threshold 64000000 load-source-file-function nil)')

# The .el files behind lisp/Makefile's OBJECTS, in order, or $null.
function Get-CompileList([string]$LispDir) {
    $makefile = Join-Path $LispDir 'Makefile'
    if (-not (Test-Path -LiteralPath $makefile -PathType Leaf)) { return $null }
    $text = [regex]::Replace([IO.File]::ReadAllText($makefile), '\\\r?\n', ' ')
    $vars = @{}
    foreach ($line in [regex]::Split($text, '\r?\n')) {
        $m = [regex]::Match($line, '^([A-Z_]+)\s*=\s*(.*)$')
        if ($m.Success) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    if (-not $vars.ContainsKey('OBJECTS')) { return $null }
    $files = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($ref in [regex]::Matches($vars['OBJECTS'], '\$\(([A-Z_]+)\)')) {
        $group = $ref.Groups[1].Value
        if (-not $vars.ContainsKey($group)) { continue }
        foreach ($word in ($vars[$group] -split '\s+')) {
            if ($word -match '^[A-Za-z0-9_.+-]+\.elc$' -and -not $seen.ContainsKey($word)) {
                $seen[$word] = $true
                $files.Add($word.Substring(0, $word.Length - 1))
            }
        }
    }
    return , $files
}

function Invoke-ByteCompile([string]$LispDir) {
    $list = Get-CompileList $LispDir
    if ($null -eq $list -or $list.Count -lt 10) {
        Fail ("could not read the list of files to compile from $LispDir\Makefile; its " +
              'format may have changed. Rerun with -NoCompile to run emacspeak from source.')
    }
    $deps = @('-l', (Join-Path $LispDir 'emacspeak-preamble.el'), '-l', (Join-Path $LispDir 'emacspeak-loaddefs.el'))
    $compiled = 0
    $current = 0
    $optedOut = 0
    $missing = @()
    $failed = @()
    foreach ($el in $list) {
        $src = Join-Path $LispDir $el
        $elc = $src + 'c'
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $el; continue }
        # emacspeak-loaddefs.el, for one, asks not to be compiled; Emacs
        # would skip it and write no .elc.
        if (Select-String -LiteralPath $src -SimpleMatch -Pattern 'no-byte-compile: t' -Quiet) {
            $optedOut++
            continue
        }
        if ((Test-Path -LiteralPath $elc -PathType Leaf) -and
            (Get-Item -LiteralPath $elc).LastWriteTimeUtc -ge (Get-Item -LiteralPath $src).LastWriteTimeUtc) {
            $current++
            continue
        }
        $r = Invoke-Program -FilePath $EmacsExe -WorkingDirectory $LispDir -Seconds 600 `
            -Arguments ($EmacsBatch + $deps + @('-f', 'batch-byte-compile', $el))
        if ($r.Started -and -not $r.TimedOut -and $r.ExitCode -eq 0 -and (Test-Path -LiteralPath $elc)) {
            $compiled++
            if ($compiled % 50 -eq 0) { Write-Info "Compiled $compiled of up to $($list.Count) files so far." }
        } else {
            $failed += $el
        }
    }
    Write-Info "Compiled $compiled files; $current were up to date, and $optedOut ask to stay source."
    if ($missing.Count -gt 0) {
        Write-Warn "the Makefile lists files this clone lacks: $($missing -join ', ')"
    }
    if ($failed.Count -gt 0) {
        Write-Warn ("$($failed.Count) files did not compile and load from source instead: " +
                    "$($failed -join ', '). Their errors are in the log.")
    }
    $script:CompileText = "byte-compiled ($compiled now, $current up to date, $($failed.Count) failed)"
}

# --------------------------------------------------------------------------
# Files this script writes into the prefix.

function Get-InitText {
    $template = @'
;;; omnivox-init.el --- emacspeak with OmniVox speech  -*- lexical-binding: t; coding: utf-8 -*-
;; @MARKER@, which rewrites it on every run.
;; Load it from your own init file, or copy these settings there.
;; Keep your own settings in omnivox-local.el beside this file: it is
;; loaded below if it exists, and the script never changes it.

;; A newer .el wins over an older .elc, so a stale compiled file never loads.
(setq load-prefer-newer t)
;; Emacspeak's Lisp, then OmniVox's voice module, which loads before emacspeak.
(add-to-list 'load-path "@LISP@")
(add-to-list 'load-path "@ELISP@")
;; OmniVox's voice list runs servers/omnivox.exe by name; let Emacs find it.
(add-to-list 'exec-path "@SERVERS@")
(require 'omnivox-voices)

;; Optional, best kept in omnivox-local.el:
;; M-x customize-group RET omnivox RET lists every OmniVox setting.
;; (setq omnivox-speech-rate 50)   ; 50 is normal speed; higher is faster
;; (setq omnivox-voice-id "...")   ; M-x omnivox-select-voice picks one
(load "@LOCAL@" t)

;; OmniVox plays the auditory icons itself, so its sound volume applies.
(setq emacspeak-play-program nil)
;; Native compilation runs in the background; do not pop up its warnings.
(setq native-comp-async-report-warnings-errors 'silent)

(setq dtk-program (or (getenv "DTK_PROGRAM") "omnivox"))
(load-file "@SETUP@")
'@
    $text = $template.Replace($CRLF, $LF)
    $text = $text.Replace('@MARKER@', $Marker)
    $text = $text.Replace('@LISP@', (ConvertTo-LispPath (Join-Path $PrefixPath 'lisp')))
    $text = $text.Replace('@ELISP@', (ConvertTo-LispPath (Join-Path $OmnivoxDir 'elisp')))
    $text = $text.Replace('@SERVERS@', (ConvertTo-LispPath (Join-Path $PrefixPath 'servers')))
    $text = $text.Replace('@LOCAL@', (ConvertTo-LispPath (Join-Path $PrefixPath 'omnivox-local')))
    $text = $text.Replace('@SETUP@', (ConvertTo-LispPath (Join-Path $PrefixPath 'lisp\emacspeak-setup.el')))
    return $text + $LF
}

# The self-tests' Lisp. A file, not --eval, so no quoting can go wrong.
function Get-SelfTestText {
    $template = @'
;;; omnivox-selftest.el --- self-tests of install-emacspeak-windows.ps1  -*- lexical-binding: t; -*-
;; @MARKER@, which rewrites it on every run.
;; Each function prints what it found and exits Emacs: 0 means pass.

(defun omnivox-selftest-load ()
  "Check that emacspeak and omnivox-voices loaded and Emacs finds omnivox."
  (let ((exe (executable-find "omnivox")))
    (princ (format "emacspeak loaded: %s\n" (featurep 'emacspeak)))
    (princ (format "omnivox-voices loaded: %s\n" (featurep 'omnivox-voices)))
    (princ (format "dtk-program: %s\n" dtk-program))
    (princ (format "executable-find omnivox: %s\n" exe))
    (kill-emacs (if (and (featurep 'emacspeak) (featurep 'omnivox-voices) exe) 0 1))))

(defun omnivox-selftest--run (args input)
  "Start servers/omnivox the way `dtk-make-process' does, with ARGS.
Send INPUT, close the input, wait up to 30 seconds, print what
happened, and exit with 0 when the server exited with 0."
  (let* ((process-connection-type nil)
         (default-directory (expand-file-name "~/"))
         (program (expand-file-name "omnivox" emacspeak-servers-directory))
         (output "")
         (proc nil)
         (deadline (+ (float-time) 30)))
    (princ (format "program: %s\n" program))
    (condition-case err
        (setq proc (apply #'start-process "Speaker" nil program args))
      (error (princ (format "start-process failed: %S\n" err))
             (kill-emacs 4)))
    (princ (format "running right after start: %s\n" (process-live-p proc)))
    (set-process-filter proc (lambda (_proc text) (setq output (concat output text))))
    (when input (ignore-errors (process-send-string proc input)))
    (ignore-errors (process-send-eof proc))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.5))
    (princ (format "output: %S\n" output))
    (if (process-live-p proc)
        (progn (princ "still running after 30 seconds\n")
               (delete-process proc)
               (kill-emacs 3))
      (princ (format "exit status: %s\n" (process-exit-status proc)))
      (kill-emacs (if (eql 0 (process-exit-status proc)) 0 2)))))

(defun omnivox-selftest-version ()
  "Start servers/omnivox with --version, which needs no sound."
  (omnivox-selftest--run '("--version") nil))

(defun omnivox-selftest-speak ()
  "Start the server as emacspeak does and send it version: it speaks once."
  (omnivox-selftest--run nil "version\n"))
'@
    return $template.Replace($CRLF, $LF).Replace('@MARKER@', $Marker) + $LF
}

function Get-LauncherText {
    if ($RunEmacsExe) {
        $run = '"' + $RunEmacsExe + '"'
        $check = ''
    } else {
        # No Emacs was found when this was written: use the one on PATH.
        $run = 'runemacs.exe'
        $check = ('where runemacs.exe >nul 2>nul || (echo emacspeak: runemacs.exe not found. Install ' +
                  'Emacs, then rerun install-emacspeak-windows.ps1. & exit /b 1)' + $CRLF)
    }
    $lines = @(
        '@echo off',
        'rem Emacs with emacspeak, speaking through OmniVox.',
        "rem $Marker, which rewrites it on every run.",
        'rem DTK_PROGRAM picks the speech server. -q skips your own init file,',
        'rem so emacspeak always starts the same way.',
        'setlocal',
        'if not defined DTK_PROGRAM set "DTK_PROGRAM=omnivox"'
    )
    return ($lines -join $CRLF) + $CRLF + $check + $run + ' -q -l "%~dp0omnivox-init.el" %*' + $CRLF
}

# cmd.exe reads a .cmd file in the console code page, so a path outside
# ASCII is written in that code page.
function Get-CmdEncoding([string]$Text) {
    if ($Text -notmatch '[^\x00-\x7F]') { return [Text.Encoding]::ASCII }
    try {
        return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    } catch {
        return $Utf8NoBom
    }
}

function Test-WrittenByUs([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
    return [bool](Select-String -LiteralPath $Path -SimpleMatch -Pattern $Marker -Quiet)
}

# --------------------------------------------------------------------------
# Opt-in changes outside the prefix.

function Send-SettingChange {
    # Tells running programs, Explorer above all, that the environment changed.
    try {
        if (-not ('EmacspeakInstaller.NativeMethods' -as [type])) {
            Add-Type -Namespace EmacspeakInstaller -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [void][EmacspeakInstaller.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch {
        Write-Warn 'could not tell Windows about the change; sign out and back in for it to apply everywhere.'
    }
}

function Set-UserHome {
    $current = [Environment]::GetEnvironmentVariable('HOME', 'User')
    if ($current -and $current -eq $env:USERPROFILE) {
        Write-Info "HOME is already $current for your account."
    } elseif ($current) {
        Write-Warn "HOME is already set to $current for your account; left unchanged."
    } else {
        [Environment]::SetEnvironmentVariable('HOME', $env:USERPROFILE, 'User')
        Write-Info "Set HOME to $env:USERPROFILE for your account. Programs started from now on see it."
    }
}

function Add-UserPath {
    $key = Get-Item -LiteralPath 'HKCU:\Environment'
    $raw = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $kind = 'ExpandString'
    if ($null -ne $key.GetValue('Path', $null)) { $kind = [string]$key.GetValueKind('Path') }
    $entries = @($raw -split ';' | Where-Object { $_ })
    foreach ($e in $entries) {
        if ($e.TrimEnd([char]92) -ieq $PrefixPath) {
            Write-Info "$PrefixPath is already on your PATH."
            return
        }
    }
    $new = (@($entries) + $PrefixPath) -join ';'
    New-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' -Value $new -PropertyType $kind -Force | Out-Null
    Send-SettingChange
    Write-Info "Added $PrefixPath to your PATH. New windows find the emacspeak command."
}

function New-StartMenuShortcut {
    if (-not $RunEmacsExe) {
        Write-Warn 'no Emacs was found, so no Start menu shortcut was made. Install Emacs and rerun.'
        return $null
    }
    $programs = [Environment]::GetFolderPath('Programs')
    $lnk = Join-Path $programs 'Emacspeak.lnk'
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $lnk -PathType Leaf) {
        $old = $shell.CreateShortcut($lnk)
        if (-not ([string]$old.Description).Contains($Marker)) {
            Write-Warn "$lnk exists and was not made by this script; left unchanged."
            return $null
        }
    }
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $RunEmacsExe
    $s.Arguments = '-q -l "' + $InitPath + '"'
    $s.WorkingDirectory = $env:USERPROFILE
    $s.Description = "Emacs with emacspeak and OmniVox speech. $Marker."
    $s.Save()
    Write-Info "Start menu shortcut: $lnk"
    return $lnk
}

# ==========================================================================
# Options.

$homeDir = $env:USERPROFILE
if ($env:HOME -and $env:HOME -match '^([A-Za-z]:[\\/]|[\\/][\\/])' -and
    (Test-Path -LiteralPath $env:HOME -PathType Container)) {
    $homeDir = $env:HOME
}
$DefaultPrefix = ''
if ($homeDir) { $DefaultPrefix = Join-Path $homeDir '.emacspeak' }
if ($Help) {
    Show-Usage $DefaultPrefix
    exit 0
}
$OmnivoxVersion = $OmnivoxVersion.TrimStart('v')
if ($OmnivoxVersion -and -not (Test-ValidVersion $OmnivoxVersion)) {
    Fail '-OmnivoxVersion needs a release number such as 1.3.0'
}
if (-not $Prefix) { $Prefix = $DefaultPrefix }
if (-not $Prefix) { Fail 'neither HOME nor USERPROFILE is set, so there is no default prefix. Use -Prefix.' }
if ($Prefix.Contains('"')) { Fail '-Prefix must not contain quotes' }
$PrefixPath = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Prefix))
$PrefixPath = $PrefixPath.TrimEnd([char]92, '/')
if ($PrefixPath -match '^[A-Za-z]:$' -or -not $PrefixPath) { Fail '-Prefix must be a folder, not the root of a drive' }
$ServersList = Join-Path $PrefixPath 'servers\.servers'
$OmnivoxDir = Join-Path $PrefixPath 'omnivox'
$OmnivoxExe = Join-Path $PrefixPath 'servers\omnivox.exe'
$LogOmnivoxExe = Join-Path $PrefixPath 'servers\log-omnivox.exe'
$InstalledFile = Join-Path $OmnivoxDir 'installed-version'
$InitPath = Join-Path $PrefixPath 'omnivox-init.el'
$LocalPath = Join-Path $PrefixPath 'omnivox-local.el'
$SelfTestPath = Join-Path $OmnivoxDir 'omnivox-selftest.el'
$Launcher = Join-Path $PrefixPath 'emacspeak.cmd'
$LogFile = Join-Path $PrefixPath 'install-emacspeak-windows.log'
$script:CompileText = 'not byte-compiled (-NoCompile): runs from source, starts slower'

# ==========================================================================
Add-Log ("install-emacspeak-windows.ps1 started " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $CRLF)
Write-Step 'Checking the system'
if ($env:OS -ne 'Windows_NT') {
    Fail 'this script is for Windows. For Linux and macOS, use the other installers in this folder.'
}
$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10) { Fail "this needs Windows 10 or 11, and this is Windows $os" }
$psv = $PSVersionTable.PSVersion
$NativeArch = Get-NativeArch
switch ($NativeArch) {
    'AMD64' { $Arch = 'x64' }
    'ARM64' { $Arch = 'arm64' }
    default { Fail "OmniVox has builds for x64 and ARM64 Windows only, and this computer is $NativeArch." }
}
Write-Info "Windows $os on $Arch, PowerShell ${psv}: supported."
if (Test-Path -LiteralPath (Join-Path $PrefixPath '.git')) { Open-Log $LogFile }
Write-Info "Log: $LogFile"

# --------------------------------------------------------------------------
$EmacsExe = $null
$EmacsVersion = $null
$GitExe = $null
if ($EmacsPath) {
    Write-Step 'Checking the Emacs given with -EmacsPath'
    $EmacsExe = Resolve-EmacsExe $EmacsPath
    if ($null -eq $EmacsExe) {
        Fail ("-EmacsPath: no emacs.exe at $EmacsPath. Give the full path of emacs.exe, such as " +
              'C:\Program Files\Emacs\emacs-30.2\bin\emacs.exe, or the folder of an unpacked Emacs zip.')
    }
    $EmacsVersion = Get-EmacsVersion $EmacsExe
    if ($null -eq $EmacsVersion) {
        Fail "$EmacsExe does not run in batch mode. Reinstall that Emacs, or pick another with -EmacsPath. $(Get-LogRef)"
    }
    if (-not (Test-NewEnough $EmacsVersion)) {
        Fail "emacspeak needs Emacs $MinEmacs or newer, and $EmacsExe is Emacs $EmacsVersion. Give a newer one."
    }
    Write-Info "Found Emacs $EmacsVersion."
}

if (-not $SkipDeps) {
    if ($null -eq $EmacsExe) {
        Write-Step "Looking for Emacs $MinEmacs or newer"
        $found = Find-Emacs
        if ($null -eq $found) {
            Write-Step "No Emacs $MinEmacs or newer found: installing $EmacsWingetId with winget"
            $r = Install-WithWinget $EmacsWingetId 'GNU Emacs'
            $found = Find-Emacs
            if ($null -eq $found) {
                Show-LogTail
                Fail ("winget did not install a usable Emacs (exit status $($r.ExitCode)). Install " +
                      'GNU Emacs from https://www.gnu.org/software/emacs/download.html, then rerun ' +
                      'with -EmacsPath and the path of its emacs.exe.')
            }
        }
        $EmacsExe = $found.Path
        $EmacsVersion = $found.Version
    }
    if ($null -eq (Find-Git)) {
        Write-Step "No git found: installing $GitWingetId with winget"
        $r = Install-WithWinget $GitWingetId 'Git for Windows'
        if ($null -eq (Find-Git)) {
            Show-LogTail
            Fail ("winget did not install git (exit status $($r.ExitCode)). Install Git for Windows " +
                  'from https://git-scm.com, then rerun this script.')
        }
    }
}

Write-Step 'Checking Emacs and git'
if ($null -eq $EmacsExe) {
    $found = Find-Emacs
    if ($null -ne $found) {
        $EmacsExe = $found.Path
        $EmacsVersion = $found.Version
    }
}
$RunEmacsExe = $null
if ($null -ne $EmacsExe) {
    Write-Info "Emacs ${EmacsVersion}: new enough. Using $EmacsExe"
    $candidate = Join-Path (Split-Path -Parent $EmacsExe) 'runemacs.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $RunEmacsExe = $candidate
    } else {
        Write-Warn "no runemacs.exe beside $EmacsExe; the launcher starts emacs.exe instead."
        $RunEmacsExe = $EmacsExe
    }
} else {
    Write-Warn ("no Emacs $MinEmacs or newer found, so the steps that need Emacs are skipped: " +
                'the autoloads, the byte-compiling and the Emacs self-tests. Install Emacs, ' +
                'then rerun this script, with -EmacsPath if Emacs is somewhere unusual.')
}
$GitExe = Find-Git
if ($null -eq $GitExe) {
    Fail 'git not found. Install Git for Windows from https://git-scm.com, or rerun without -SkipDeps.'
}
$gitVersion = (Invoke-Program -FilePath $GitExe -Arguments @('--version') -Seconds 60).Output.Trim()
Write-Info "Git: $gitVersion, $GitExe"
$SourceTools = $null
if ($OmnivoxSource) {
    $SourceTools = Find-SourceTools
    if ($SourceTools.Missing.Count -gt 0) {
        foreach ($m in $SourceTools.Missing) { Write-Info "Missing for -OmnivoxSource: $m" }
        Fail ('-OmnivoxSource needs Rust, CMake, LLVM and the Visual Studio C++ build tools, ' +
              'which this script does not install. Install the missing ones listed above, or ' +
              'leave out -OmnivoxSource to use the prebuilt release.')
    }
    $rustText = (Invoke-Program -FilePath $SourceTools.Rustc -Arguments @('--version') -Seconds 60).Output.Trim()
    $m = [regex]::Match($rustText, '^rustc 1\.([0-9]+)')
    if (-not $m.Success -or [int]$m.Groups[1].Value -lt 70) {
        Fail "OmniVox needs Rust 1.70 or newer, and this is: $rustText. Update it: rustup update"
    }
    Write-Info "For -OmnivoxSource: $rustText, CMake, and libclang in $($SourceTools.LibClang)."
}

# --------------------------------------------------------------------------
$OldHead = ''
$script:Hint = ("Check the internet connection and the -Repo and -Ref values. For an update, " +
                "also undo your own changes in $PrefixPath (git -C $PrefixPath status).")
if (Test-Path -LiteralPath (Join-Path $PrefixPath '.git')) {
    Write-Step "Updating emacspeak in $PrefixPath from $Repo ($Ref)"
    # Undo this script's change to servers\.servers first, so git sees an
    # unmodified file. The names are added back after the update.
    Unregister-Omnivox
    $OldHead = (Invoke-Logged -What 'reading the current commit' -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('-C', $PrefixPath, 'rev-parse', 'HEAD')).Output.Trim()
    Invoke-Logged -What "updating the clone in $PrefixPath" -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('-C', $PrefixPath, 'pull', '-q', '--ff-only', $Repo, $Ref) | Out-Null
    Register-Omnivox
} elseif ((Test-Path -LiteralPath $PrefixPath) -and
          @(Get-ChildItem -LiteralPath $PrefixPath -Force -ErrorAction SilentlyContinue).Count -gt 0) {
    Fail "$PrefixPath exists but is not a git clone of emacspeak. Move it away or use -Prefix."
} else {
    Write-Step "Cloning emacspeak ($Ref) from $Repo into $PrefixPath"
    Invoke-Logged -What 'git clone' -FilePath $GitExe -Environment $GitEnv `
        -Arguments @('clone', '-q', '--depth', '1', '--branch', $Ref, $Repo, $PrefixPath) | Out-Null
    Open-Log $LogFile
}
$NewHead = (Invoke-Program -FilePath $GitExe -Arguments @('-C', $PrefixPath, 'rev-parse', 'HEAD')).Output.Trim()
$sourceText = (Invoke-Program -FilePath $GitExe -Arguments @(
    '-C', $PrefixPath, 'log', '-1', '--format=commit %h of %cd', '--date=short')).Output.Trim()
Write-Info "Emacspeak source: $sourceText"

$LispDir = Join-Path $PrefixPath 'lisp'
$Loaddefs = Join-Path $LispDir 'emacspeak-loaddefs.el'
if ($null -ne $EmacsExe) {
    $script:Hint = ("The lines above name the Lisp file that failed. Make sure $EmacsExe starts, " +
                    'then rerun; if it still fails, ask on the emacspeak mailing list.')
    if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
        Write-Step "Generating emacspeak's autoloads (emacspeak-loaddefs.el)"
    } elseif ($OldHead -and $OldHead -ne $NewHead) {
        Write-Step "Regenerating emacspeak's autoloads for the new commits"
    } else {
        Write-Step "Emacspeak's autoloads are in place"
    }
    if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf) -or ($OldHead -and $OldHead -ne $NewHead)) {
        Invoke-Logged -What 'generating emacspeak-loaddefs.el' -FilePath $EmacsExe -WorkingDirectory $LispDir `
            -Arguments ($EmacsBatch + @('-l', './emacspeak-preamble.el', '-l', './emacspeak-autoload.el',
                                        '-f', 'emacspeak-auto-generate-autoloads')) | Out-Null
        if (-not (Test-Path -LiteralPath $Loaddefs -PathType Leaf)) {
            Fail "Emacs finished, but $Loaddefs is missing. $script:Hint $(Get-LogRef)"
        }
        Write-Info 'Written.'
    } else {
        Write-Info 'emacspeak-loaddefs.el is up to date.'
    }
    if ($NoCompile) {
        Write-Step 'Not byte-compiling emacspeak (-NoCompile): it runs from source'
    } else {
        Write-Step "Byte-compiling emacspeak's Lisp (each file in its own Emacs, a few minutes)"
        Invoke-ByteCompile $LispDir
    }
} else {
    $script:CompileText = 'not set up: no Emacs found'
}

# --------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OmnivoxDir | Out-Null
$Installed = ''
if (Test-Path -LiteralPath $InstalledFile -PathType Leaf) {
    $Installed = ([IO.File]::ReadAllText($InstalledFile)).Trim()
}
Write-Step 'Choosing the OmniVox release'
# Latest by default, so rerunning this script also updates OmniVox. The
# checksum file comes from the same release: it catches a damaged download.
if ($OmnivoxVersion) {
    Write-Info "OmniVox $OmnivoxVersion, as asked with -OmnivoxVersion."
} else {
    $latest = Get-LatestOmnivoxVersion
    if ($latest) {
        $OmnivoxVersion = $latest
        Write-Info "Latest OmniVox release: $OmnivoxVersion"
    } elseif ($Installed) {
        $OmnivoxVersion = ($Installed -split ' ')[0]
        Write-Warn "could not ask GitHub for the latest OmniVox release; keeping $OmnivoxVersion."
    } else {
        $OmnivoxVersion = $OmnivoxFallback
        Write-Warn "could not ask GitHub for the latest OmniVox release; using $OmnivoxVersion."
    }
}
if ($OmnivoxSource) {
    $Want = "$OmnivoxVersion source"
    $RouteText = 'built from source'
} else {
    $Want = "$OmnivoxVersion windows-$Arch"
    $RouteText = "prebuilt for $Arch, checksum verified"
}
if ($Installed -eq $Want -and (Test-Path -LiteralPath $OmnivoxExe -PathType Leaf) -and
    (Test-Path -LiteralPath $LogOmnivoxExe -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $OmnivoxDir 'elisp\omnivox-voices.el') -PathType Leaf)) {
    Write-Info "OmniVox $OmnivoxVersion ($RouteText) is already installed; keeping it."
} elseif ($OmnivoxSource) {
    Build-OmnivoxFromSource $OmnivoxVersion
} else {
    Install-PrebuiltOmnivox $OmnivoxVersion
}

Write-Step "Registering OmniVox in $ServersList"
Register-Omnivox
Write-Info 'Listed: omnivox, log-omnivox.'

Write-Step "Writing $InitPath"
[IO.File]::WriteAllText($InitPath, (Get-InitText), $Utf8NoBom)
[IO.File]::WriteAllText($SelfTestPath, (Get-SelfTestText), $Utf8NoBom)
Write-Info 'Written, with the self-test file omnivox\omnivox-selftest.el.'

Write-Step "Writing the launcher $Launcher"
if (-not (Test-WrittenByUs $Launcher)) {
    Fail "$Launcher exists and was not written by this script. Move it away, then rerun."
}
$launcherText = Get-LauncherText
[IO.File]::WriteAllText($Launcher, $launcherText, (Get-CmdEncoding $launcherText))
if ($RunEmacsExe) {
    Write-Info "Launcher written; it starts $RunEmacsExe"
} else {
    Write-Info 'Launcher written; it starts the runemacs.exe on PATH, since no Emacs was found.'
}

$Shortcut = $null
if ($StartMenuShortcut) {
    Write-Step 'Adding Emacspeak to the Start menu (-StartMenuShortcut)'
    $Shortcut = New-StartMenuShortcut
}
if ($SetHome) {
    Write-Step 'Setting HOME for your account (-SetHome)'
    Set-UserHome
}
if ($AddToPath) {
    Write-Step 'Adding the prefix to your PATH (-AddToPath)'
    Add-UserPath
}

# --------------------------------------------------------------------------
# Self-tests. Only the last one needs a sound output device, and it is
# skipped when OmniVox finds none. Without Emacs, the Emacs ones are skipped.
$Passed = 0
# Skipped test numbers by reason, in order, for one short summary line.
$SkipReasons = New-Object System.Collections.Specialized.OrderedDictionary
function Skip-Test([int]$Number, [string]$Why) {
    Write-Info "Skipped: $Why."
    $reason = ($Why -split ';')[0]
    if (-not $SkipReasons.Contains($reason)) { $SkipReasons[$reason] = @() }
    $SkipReasons[$reason] = @($SkipReasons[$reason]) + $Number
}
$SpeechFix = ('Install a voice in Settings, Time and language, Speech, and run this in your own ' +
              'signed-in Windows session, not over a remote shell.')
if (-not $NoTest) {
    Write-Step "Self-test 1 of ${TestCount}: OmniVox reports its version"
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--version') -Seconds 30
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Fail "Self-test 1 failed: $OmnivoxExe --version did not run. Rerun with -OmnivoxSource to build it here. $(Get-LogRef)"
    }
    $out = $r.Output.Trim()
    if ($out -notmatch '^omnivox [0-9]') {
        Fail "Self-test 1 failed: $OmnivoxExe --version printed: $out. Rerun the script."
    }
    Write-Info "Pass: $out."
    $Passed++

    Write-Step "Self-test 2 of ${TestCount}: OmniVox lists the system voices"
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--list-voices') -Seconds 60
    if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Fail "Self-test 2 failed: $OmnivoxExe --list-voices did not finish. $SpeechFix $(Get-LogRef)"
    }
    $m = [regex]::Match($r.Output + $LF + $r.ErrorOutput, '(?m)^Found ([0-9]+) voices')
    if (-not $m.Success -or [int]$m.Groups[1].Value -lt 1) {
        Fail "Self-test 2 failed: OmniVox found no voices. $SpeechFix"
    }
    Write-Info "Pass: $($m.Groups[1].Value) voices."
    $Passed++

    Write-Step "Self-test 3 of ${TestCount}: OmniVox's own check synthesizes speech"
    Write-Info 'With a sound device, you may hear a tone and: Omnivox is ready.'
    $r = Invoke-Program -FilePath $OmnivoxExe -Arguments @('--check') -Seconds 120
    if (-not $r.Started -or $r.TimedOut) {
        Fail "Self-test 3 failed: $OmnivoxExe --check did not finish. $SpeechFix $(Get-LogRef)"
    }
    $report = $r.Output + $LF + $r.ErrorOutput
    if ($report -notmatch 'Status: OK - ') {
        Fail "Self-test 3 failed: OmniVox could not synthesize speech. $SpeechFix Its report is in the log. $(Get-LogRef)"
    }
    $Sound = $report -match 'Audio device: OK'
    if ($Sound) {
        Write-Info 'Pass: speech synthesized, and a sound output device was found.'
    } else {
        Write-Info 'Pass: speech synthesized. No sound output device was found.'
    }
    $Passed++

    Write-Step "Self-test 4 of ${TestCount}: Emacs is $MinEmacs or newer"
    if ($null -eq $EmacsExe) {
        Skip-Test 4 'no Emacs found'
    } else {
        $v = Get-EmacsVersion $EmacsExe
        if ($null -eq $v -or -not (Test-NewEnough $v)) {
            Fail "Self-test 4 failed: $EmacsExe is not Emacs $MinEmacs or newer. Install a newer one, or use -EmacsPath."
        }
        Write-Info "Pass: Emacs $v."
        $Passed++
    }

    Write-Step "Self-test 5 of ${TestCount}: Emacs loads the init file and finds OmniVox (no speech)"
    if ($null -eq $EmacsExe) {
        Skip-Test 5 'no Emacs found'
    } else {
        $r = Invoke-Program -FilePath $EmacsExe -Seconds 300 -Environment @{ DTK_PROGRAM = 'omnivox' } `
            -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $SelfTestPath, '-f', 'omnivox-selftest-load')
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
            Show-LogTail
            Fail ("Self-test 5 failed: Emacs could not load $InitPath, or emacspeak does not " +
                  "find $OmnivoxExe. Rerun the script to rebuild both. $(Get-LogRef)")
        }
        Write-Info 'Pass: emacspeak and omnivox-voices load, and Emacs finds omnivox.exe.'
        $Passed++
    }

    Write-Step "Self-test 6 of ${TestCount}: Emacs starts servers/omnivox by its bare name, as emacspeak does (no speech)"
    if ($null -eq $EmacsExe) {
        Skip-Test 6 'no Emacs found'
    } else {
        $r = Invoke-Program -FilePath $EmacsExe -Seconds 120 `
            -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $SelfTestPath, '-f', 'omnivox-selftest-version')
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $r.Output -notmatch 'output: "omnivox [0-9]') {
            Show-LogTail
            Fail ("Self-test 6 failed: Emacs's start-process could not run $PrefixPath\servers\omnivox " +
                  "without its .exe, which is how emacspeak starts its server. Report this to the " +
                  "maintainers of this script with the log. $(Get-LogRef)")
        }
        Write-Info 'Pass: start-process ran servers/omnivox, which is omnivox.exe, and it printed its version.'
        $Passed++
    }

    Write-Step "Self-test 7 of ${TestCount}: OmniVox is registered and the launcher is in place"
    $names = Get-ServersNames ([IO.File]::ReadAllText($ServersList))
    foreach ($name in @('omnivox', 'log-omnivox')) {
        if ($names -notcontains $name) { Fail "Self-test 7 failed: $ServersList does not list $name. Rerun the script." }
    }
    if (-not (Test-Path -LiteralPath $LogOmnivoxExe -PathType Leaf)) {
        Fail "Self-test 7 failed: $LogOmnivoxExe is missing. Rerun the script."
    }
    if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) {
        Fail "Self-test 7 failed: $Launcher is missing. Rerun the script."
    }
    Write-Info 'Pass: both names are listed, log-omnivox.exe is there, and so is the launcher.'
    $Passed++

    Write-Step "Self-test 8 of ${TestCount}: the OmniVox server speaks, started the way emacspeak starts it"
    if ($null -eq $EmacsExe) {
        Skip-Test 8 'no Emacs found'
    } elseif (-not $Sound) {
        Skip-Test 8 'no sound output device; connect speakers or headphones, then rerun'
    } else {
        Write-Info "This speaks once. You should hear: Omnivox version $OmnivoxVersion."
        $r = Invoke-Program -FilePath $EmacsExe -Seconds 120 `
            -Arguments @('-Q', '--batch', '-l', $InitPath, '-l', $SelfTestPath, '-f', 'omnivox-selftest-speak')
        if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0) {
            Show-LogTail
            Fail ("Self-test 8 failed: the server did not start or exit cleanly. Check the sound " +
                  "output in Settings, System, Sound, then rerun. $(Get-LogRef)")
        }
        Write-Info 'Pass: the server spoke its version and exited cleanly.'
        $Passed++
    }
    if ($Passed -eq $TestCount) {
        $TestsText = "all $TestCount passed"
    } else {
        $notes = @()
        foreach ($reason in $SkipReasons.Keys) {
            $numbers = @($SkipReasons[$reason])
            if ($numbers.Count -eq 1) {
                $notes += "test $($numbers[0]) skipped, $reason"
            } else {
                $notes += "tests $($numbers -join ', ') skipped, $reason"
            }
        }
        $TestsText = "$Passed of $TestCount passed; " + ($notes -join '; ')
    }
} else {
    $TestsText = 'skipped (-NoTest)'
}

# --------------------------------------------------------------------------
$initLine = '(load-file "' + (ConvertTo-LispPath $InitPath) + '")'
if ($env:HOME) {
    $emacsHome = $env:HOME
} else {
    $emacsHome = $env:APPDATA
}
if ($null -ne $EmacsExe) {
    Write-Step 'Done: emacspeak is installed'
} else {
    Write-Step 'Done, but incomplete: no Emacs found'
}
$summary = @(
    "Self-tests: $TestsText",
    "Emacspeak is in $PrefixPath",
    "Its Lisp is $($script:CompileText).",
    "Speech server: OmniVox $OmnivoxVersion, $RouteText",
    "OmniVox is in $PrefixPath\servers"
)
if ($null -ne $EmacsExe) {
    $summary += "Emacs ${EmacsVersion}: $EmacsExe"
} else {
    $summary += 'Emacs: none found. Install Emacs 29.1 or newer, then rerun this script.'
}
$summary += @(
    "Launcher: $Launcher",
    "Log: $LogFile",
    '',
    'To start it, run the launcher from File Explorer, the Run box,',
    'a Command Prompt or PowerShell:',
    "  $Launcher",
    'It starts Emacs without your own init file (-q), and',
    'DTK_PROGRAM=omnivox picks the OmniVox server.',
    'To load emacspeak from your own Emacs init file instead, put',
    'this line at the very top of it:',
    "  $initLine",
    "Emacs looks for your init file in $emacsHome\.emacs.d",
    '',
    'NVDA and JAWS speak over emacspeak unless you pause them.',
    'NVDA: press NVDA+Shift+S in the Emacs window for sleep mode',
    '(NVDA+Shift+Z on the laptop layout); press it again to wake NVDA.',
    'JAWS has a similar sleep mode: INSERT+SPACEBAR, then Z.',
    '',
    'Speech rate: OmniVox starts at 60, about twice normal speed on',
    'Windows. M-x omnivox-set-rate RET 50 RET is normal speed, and',
    'higher numbers are faster. To keep a rate, put this line',
    '  (setq omnivox-speech-rate 50)',
    'in this file, which the script never changes:',
    "  $LocalPath",
    'To choose a voice in Emacs: M-x omnivox-select-voice',
    'Known OmniVox issue: text after two semicolons may not be spoken.'
)
if ($Shortcut) { $summary += @('', "Start menu: Emacspeak, $Shortcut") }
$notUsed = @()
if (-not $AddToPath) {
    $notUsed += @('  -AddToPath puts the prefix on your PATH, so typing emacspeak',
                  '  starts it in any new window.')
}
if (-not $SetHome) {
    $notUsed += @('  -SetHome sets HOME to your profile folder, as OmniVox advises',
                  '  for loading emacspeak from your own init file. Emacs then',
                  '  looks for .emacs.d there instead of in %APPDATA%, so move',
                  '  your .emacs.d there first if you have one.')
}
if (-not $StartMenuShortcut) {
    $notUsed += '  -StartMenuShortcut adds Emacspeak to your Start menu.'
}
if ($notUsed.Count -gt 0) {
    $summary += @('', 'Left unchanged, as by default. Rerun with these to change them:') + $notUsed
}
$summary += @('', 'To update emacspeak and OmniVox later, run this script again.')
foreach ($line in $summary) { Write-Info $line }
exit 0
