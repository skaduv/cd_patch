# Claude Desktop compatible builds: Gateway models + Simplified Chinese + CU/Browser.

[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$PythonPath = '',
    [string]$NodePath = '',
    [switch]$CheckOnly,
    [Alias('RestoreOriginal')][switch]$Restore,
    [switch]$SkipSyntaxCheck,
    [switch]$NoAclChange,
    [string]$LanguageDir = '',
    [switch]$NoLanguage,
    [switch]$ElevatedChild
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Info([string]$Message) { Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Test-PythonCandidate([string]$Candidate) {
    # Returns 'major.minor' when the candidate is a usable Python 3.10+, else $null.
    # Probes the candidate with '--version'. A Microsoft Store placeholder
    # (a 0-byte app-execution alias when no Store Python is installed) fails
    # the probe, while a genuinely Store-installed Python passes it, so the
    # file size must not be used to judge usability.
    try {
        $null = Get-Item -LiteralPath $Candidate -ErrorAction Stop
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Candidate
        $psi.Arguments = '--version'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(15000)) { try { $proc.Kill() } catch {}; return $null }
        $out = ($proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()).Trim()
        if ($proc.ExitCode -ne 0) { return $null }
        if ($out -match 'Python\s+(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 10)) { return "$major.$minor" }
        }
        return $null
    } catch { return $null }
}
function Resolve-Python([string]$Given) {
    if ($Given) {
        $p = (Resolve-Path -LiteralPath $Given -ErrorAction Stop).Path
        $ver = Test-PythonCandidate $p
        if (-not $ver) { throw "The Python at '$p' is not usable (need Python 3.10+)." }
        return @{ Path = $p; Version = $ver }
    }
    $candidates = @()
    $found = @(Get-Command python.exe -All -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($f in $found) { $candidates += $f.Source }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe')
    $tried = @()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $tried += $candidate
        $ver = Test-PythonCandidate $candidate
        if ($ver) { return @{ Path = $candidate; Version = $ver } }
    }
    $hint = if ($tried.Count) { 'Tried: ' + ($tried -join ', ') } else { 'No python.exe found on PATH.' }
    throw "Python 3.10+ was not found or not usable. $hint Install Python 3.10+ or pass -PythonPath explicitly."
}
function Resolve-Node([string]$Given) {
    # Returns the node.exe path, or $null when none is available (caller warns and skips).
    # An explicitly given path must be a file: silently falling back would ignore
    # the user's explicit choice.
    if ($Given) {
        $p = (Resolve-Path -LiteralPath $Given -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "The Node.js path '$p' is not a file." }
        return $p
    }
    $candidates = @()
    $found = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($found) { $candidates += $found.Source }
    $candidates += 'D:\nodejs\node.exe'
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
function Stop-TargetClaude([string]$TargetApp) {
    $targetExe = [IO.Path]::GetFullPath((Join-Path $TargetApp 'claude.exe'))
    $killed = 0
    Get-Process -Name claude -ErrorAction SilentlyContinue | ForEach-Object {
        try { $processExe = $_.Path } catch { $processExe = $null }
        if ($processExe -and [string]::Equals($processExe,$targetExe,[StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $_.Id -Force
            $killed++
        }
    }
    if ($killed -gt 0) {
        Info "Stopped $killed Claude process(es); waiting briefly for file locks to release."
        Start-Sleep -Milliseconds 800
    }
}
function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function ConvertTo-QuotedArgument([string]$Value) {
    # Windows command-line quoting: escape embedded quotes and double any
    # backslashes that precede a quote, so values such as 'C:\' survive intact.
    $escaped = [regex]::Replace($Value,'(\\*)"',{ param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped,'(\\+)$',{ param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}
function Invoke-SelfElevated([System.Collections.IDictionary]$Bound) {
    # Relaunch this script elevated with the same arguments and wait for it.
    # The elevated run keeps its own window open at the end so its output can be read.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'))
    foreach ($key in @($Bound.Keys)) {
        if ($key -eq 'ElevatedChild') { continue }
        $value = $Bound[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $argList += ('-' + $key) }
        } else {
            $argList += ('-' + $key)
            $argList += (ConvertTo-QuotedArgument ([string]$value))
        }
    }
    $argList += '-ElevatedChild'
    $hostExe = (Get-Process -Id $PID).Path
    Info 'Administrator rights are required. Approve the UAC prompt; output continues in the new window.'
    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        throw 'Elevation was cancelled or failed. Run PowerShell as administrator and retry.'
    }
    return $proc.ExitCode
}
function Get-NormalizedRoot([string]$Root) {
    return [IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()
}
function Get-AclBackupPath([string]$Root) {
    # Bind the backup to the normalized full install path: the file name carries a
    # hash of it, and a sidecar '.path' file records it for verification.
    $norm = Get-NormalizedRoot $Root
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))[0..7] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $dir = Join-Path $env:LOCALAPPDATA 'ClaudeDesktopPatch'
    return Join-Path $dir ('acl-' + (Split-Path $Root -Leaf) + '-' + $hash + '.txt')
}
function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Write-AclBackupBinding([string]$Root,[string]$AclBackup) {
    # Sidecar '.path': line 1 the normalized install path, line 2 the SHA256 of the
    # DACL save file, line 3 the SHA256 of the per-item owner list.
    $text = (Get-NormalizedRoot $Root) + "`n" + (Get-FileSha256 $AclBackup) + "`n" + (Get-FileSha256 ($AclBackup + '.owners')) + "`n"
    [IO.File]::WriteAllText($AclBackup + '.path',$text,[Text.UTF8Encoding]::new($false))
}
function Assert-AclBackupBinding([string]$Root,[string]$AclBackup) {
    $bindingPath = $AclBackup + '.path'
    $ownersPath = $AclBackup + '.owners'
    if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) { throw "ACL backup has no path binding: $AclBackup" }
    if (-not (Test-Path -LiteralPath $ownersPath -PathType Leaf)) { throw "ACL backup has no owner list: $ownersPath" }
    $binding = @([IO.File]::ReadAllLines($bindingPath,[Text.Encoding]::UTF8) | ForEach-Object { $_.Trim() })
    if ($binding.Count -lt 3) { throw "ACL backup binding is incomplete: $bindingPath" }
    if ($binding[0] -ne (Get-NormalizedRoot $Root)) { throw "ACL backup $AclBackup belongs to '$($binding[0])', not '$Root'." }
    if ((Get-FileSha256 $AclBackup) -ne $binding[1] -or (Get-FileSha256 $ownersPath) -ne $binding[2]) {
        throw "ACL backup $AclBackup failed its integrity check (contents changed since it was saved)."
    }
}
function Save-InstallOwners([string]$Root,[string]$OwnersPath) {
    # icacls /save keeps only DACLs, so record every item's original owner.
    # Derive relative paths from the root as the file system reports it, so a
    # differently formed InstallLocation (prefix, short name) cannot skew them.
    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    $rootFull = $rootItem.FullName.TrimEnd('\')
    $items = @($rootItem) + @(Get-ChildItem -LiteralPath $rootItem.FullName -Recurse -Force -ErrorAction Stop)
    $lines = foreach ($item in $items) {
        $owner = (Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).Owner
        if (-not $owner) { throw "Cannot read the owner of $($item.FullName)." }
        $itemFull = $item.FullName.TrimEnd('\')
        if ($itemFull -eq $rootFull) { $rel = '' }
        elseif ($itemFull.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) { $rel = $itemFull.Substring($rootFull.Length + 1) }
        else { throw "Item $($item.FullName) is not under the install folder $rootFull." }
        $owner + "`t" + $rel
    }
    [IO.File]::WriteAllLines($OwnersPath,[string[]]$lines,[Text.UTF8Encoding]::new($false))
}
function ConvertTo-IcaclsAccount([string]$Owner) {
    if ($Owner -match '^S-1-') { return '*' + $Owner }
    return $Owner
}
function Resolve-ContainedPath([string]$Root,[string]$Relative) {
    # Map a backup-relative path to a full path that must stay inside $Root and
    # must not pass through a reparse point (junction/symlink). Returns $null if not.
    if ($Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative -match ':' -or $Relative.StartsWith('\') -or $Relative.StartsWith('/')) { return $null }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = if ($Relative) { [IO.Path]::GetFullPath((Join-Path $rootFull $Relative)) } else { $rootFull }
    if ($full -ne $rootFull -and -not $full.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) { return $null }
    $cursor = $full
    while ($cursor.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $attrs = (Get-Item -LiteralPath $cursor -Force).Attributes
            if ($attrs -band [IO.FileAttributes]::ReparsePoint) { return $null }
        }
        if ($cursor -eq $rootFull) { break }
        $cursor = Split-Path $cursor -Parent
    }
    return $full
}
function Test-AclSaveFilePaths([string]$Root,[string]$AclBackup) {
    # icacls /restore applies paths relative to the parent folder; every entry must
    # name this install folder or something beneath it.
    $leaf = Split-Path $Root -Leaf
    $lines = @([IO.File]::ReadAllLines($AclBackup,[Text.Encoding]::Unicode) | Where-Object { $_.Trim() })
    for ($i = 0; $i -lt $lines.Count; $i += 2) {
        $path = $lines[$i].Trim()
        if ($path -ne $leaf -and -not $path.StartsWith($leaf + '\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Resolve-ContainedPath $Root $path.Substring($leaf.Length).TrimStart('\'))) { return $false }
    }
    return $true
}
function Restore-InstallOwners([string]$Root,[string]$OwnersPath) {
    # Restore owners only for the items recorded before the first permission change;
    # items created later (for example patch-backup) keep their current owner.
    $entries = @([IO.File]::ReadAllLines($OwnersPath,[Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object {
        $parts = $_.Split("`t",2); [pscustomobject]@{ Owner = $parts[0]; Path = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
    })
    if ($entries.Count -eq 0) { return 1 }
    $result = 0
    foreach ($entry in $entries) {
        $full = Resolve-ContainedPath $Root $entry.Path
        if (-not $full) { Write-Host "ERROR: Owner list entry outside the install folder rejected: $($entry.Path)" -ForegroundColor Red; $result = 1; continue }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        & icacls.exe $full /setowner (ConvertTo-IcaclsAccount $entry.Owner) /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { $result = $LASTEXITCODE }
    }
    return $result
}
function Test-InstallWritable([string]$Root,[string]$App) {
    $dirs = @($Root,$App,(Join-Path $App 'resources'),(Join-Path $App 'resources\ion-dist\assets\v1'),(Join-Path $App 'resources\ion-dist\i18n'))
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $probe = Join-Path $dir ('.claude-patch-probe-' + [Guid]::NewGuid().ToString('N'))
        try {
            ([IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)).Dispose()
            Remove-Item -LiteralPath $probe -Force
        } catch { return $false }
    }
    # Every existing file the engine may rewrite: exe, asar and the frontend JS assets.
    $files = @((Join-Path $App 'claude.exe'),(Join-Path $App 'resources\app.asar'))
    $assetDir = Join-Path $App 'resources\ion-dist\assets\v1'
    if (Test-Path -LiteralPath $assetDir -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $assetDir -Filter '*.js' -File -Force | ForEach-Object { $_.FullName })
    }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try { ([IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)).Dispose() }
        catch { return $false }
    }
    return $true
}
function Grant-InstallWriteAccess([string]$Root) {
    # WindowsApps package folders are owned by TrustedInstaller and Administrators
    # only get read/execute, so elevation alone cannot write them. Save the
    # original DACL once (kept across re-runs), then take ownership for
    # Administrators and grant Administrators + the current user full control.
    $aclBackup = Get-AclBackupPath $Root
    if (Test-Path -LiteralPath $aclBackup -PathType Leaf) {
        # Reuse only a backup that still matches this directory and its recorded
        # checksums; otherwise stop before any permission change.
        Assert-AclBackupBinding $Root $aclBackup
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $aclBackup -Parent) | Out-Null
        Info "Saving original ACL to $aclBackup"
        # No /C: icacls stops at the first item it cannot read, so exit 0 means every item was saved.
        & icacls.exe $Root /save $aclBackup /T /Q | Out-Null
        $saveExit = $LASTEXITCODE
        $saved = 0
        if (Test-Path -LiteralPath $aclBackup -PathType Leaf) {
            # The save file is UTF-16LE: one line with the item path, one with its SDDL.
            $lines = @([IO.File]::ReadAllLines($aclBackup,[Text.Encoding]::Unicode) | Where-Object { $_.Trim() })
            $saved = [int][Math]::Floor($lines.Count / 2)
        }
        $expected = 1 + @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop).Count
        if ($saveExit -ne 0 -or $saved -lt $expected) {
            if (Test-Path -LiteralPath $aclBackup) { Remove-Item -LiteralPath $aclBackup -Force }
            throw "Could not save a complete ACL backup (icacls exit $saveExit, saved $saved of $expected items); no permissions were changed."
        }
        try {
            Save-InstallOwners $Root ($aclBackup + '.owners')
            Write-AclBackupBinding $Root $aclBackup
        } catch {
            foreach ($f in @($aclBackup,($aclBackup + '.owners'),($aclBackup + '.path'))) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
            throw ('Could not save the original owners: ' + $_.Exception.Message + ' No permissions were changed.')
        }
    }
    # Set before any ownership/ACL change (also when the backup already existed),
    # so a failed patch always reverts the permissions this run changed.
    $script:AclGrantedThisRun = $true
    Info 'Taking ownership of the Claude installation for Administrators...'
    & takeown.exe /F $Root /A /R /D Y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "takeown failed (exit $LASTEXITCODE). Original ACL backup: $aclBackup" }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Info 'Granting write access to Administrators and the current user...'
    & icacls.exe $Root /grant '*S-1-5-32-544:(OI)(CI)F' ('*' + $me + ':(OI)(CI)F') /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /grant failed (exit $LASTEXITCODE). Original ACL backup: $aclBackup" }
}
function Restore-InstallAcl([string]$Root) {
    $aclBackup = Get-AclBackupPath $Root
    if (-not (Test-Path -LiteralPath $aclBackup -PathType Leaf)) { return $true }
    try { Assert-AclBackupBinding $Root $aclBackup }
    catch { Write-Host ('ERROR: ' + $_.Exception.Message + ' Permissions were not restored.') -ForegroundColor Red; return $false }
    if (-not (Test-AclSaveFilePaths $Root $aclBackup)) {
        Write-Host "ERROR: ACL backup $aclBackup lists paths outside the install folder. Permissions were not restored." -ForegroundColor Red
        return $false
    }
    Info 'Restoring original ACL and per-item ownership...'
    & icacls.exe (Split-Path $Root -Parent) /restore $aclBackup /C /Q | Out-Null
    $restoreExit = $LASTEXITCODE
    $ownerExit = Restore-InstallOwners $Root ($aclBackup + '.owners')
    if ($restoreExit -eq 0 -and $ownerExit -eq 0) {
        Remove-Item -LiteralPath $aclBackup -Force
        Remove-Item -LiteralPath ($aclBackup + '.owners') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($aclBackup + '.path') -Force -ErrorAction SilentlyContinue
        Info 'Original permissions restored.'
        return $true
    }
    Write-Host "ERROR: Permission restore incomplete (restore exit $restoreExit, setowner exit $ownerExit). ACL backup kept: $aclBackup" -ForegroundColor Red
    return $false
}
function Check-Manifest([string]$Root) {
    $manifestPath = Join-Path $Root 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'AppxManifest.xml is missing.' }
    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifest.Package.Identity.Name -ne 'Claude') {
        throw 'The selected package is not Claude.'
    }
    if ($manifest.Package.Identity.ProcessorArchitecture -ne 'x64') { throw 'Only x64 was verified.' }
}
$exitCode = 0
$script:AclGrantedThisRun = $false
try {
    if ($Restore -and $CheckOnly) { throw '-Restore cannot be combined with -CheckOnly.' }
    if ($NoLanguage -and $LanguageDir) { throw '-NoLanguage cannot be combined with -LanguageDir.' }
    if ($LanguageDir) {
        # Resolve now: the elevated child starts in another working directory.
        $LanguageDir = (Resolve-Path -LiteralPath $LanguageDir).Path
        $PSBoundParameters['LanguageDir'] = $LanguageDir
    }
    if (-not $CheckOnly -and -not (Test-IsAdmin)) {
        if ($ElevatedChild) { throw 'Elevation did not produce an administrator session.' }
        exit (Invoke-SelfElevated $PSBoundParameters)
    }
    $installed = @(Get-AppxPackage -Name Claude -ErrorAction Stop)
    if ($InstallDir) {
        $InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\')
        $installed = @($installed | Where-Object { $_.InstallLocation.TrimEnd('\') -eq $InstallDir })
    }
    if ($installed.Count -ne 1) { throw 'Expected one registered Claude installation for the current user. If multiple exist, select one with -InstallDir.' }
    $InstallDir = $installed[0].InstallLocation
    Check-Manifest $InstallDir
    $AppDir = Join-Path $InstallDir 'app'
    $py = Resolve-Python $PythonPath
    $PythonPath = $py.Path
    Info "Using Python $($py.Version): $PythonPath"
    $skipSyntax = $false
    if ($Restore) { $NodePath = 'unused-for-restore' }
    elseif ($SkipSyntaxCheck) { $NodePath = 'skipped'; $skipSyntax = $true; Info 'JavaScript syntax check skipped (-SkipSyntaxCheck).' }
    else {
        $nodeFound = Resolve-Node $NodePath
        if ($nodeFound) { $NodePath = $nodeFound; Info "Using Node.js: $NodePath" }
        else { $NodePath = 'skipped'; $skipSyntax = $true; Write-Warning 'Node.js was not found; skipping JavaScript syntax verification.' }
    }
    Info "Target current Claude installation: $InstallDir"

    # Backend is embedded to keep the patch engine in a single PS1.
    $backend = @'
"""Claude Desktop 2.31226.1.0 patch engine. Standard library only.

Patches the registered installation in place; package registration is unchanged.
"""
import argparse, copy, hashlib, json, os, pathlib, re, shutil, struct, subprocess, sys, tempfile, xml.etree.ElementTree as ET

VERSION = '2.31226.1.0'
VALID_ID = r'typeof e==="string"&&e.trim().length>0&&!/[\x00-\x1f\x7f-\x9f]/.test(e)'

def sha(b): return hashlib.sha256(b).hexdigest()
def dump(o): return json.dumps(o, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
def log(s): print(s, flush=True)

# ---- Simplified Chinese (official Anthropic catalogs) ----
# Claude ships Simplified Chinese as locale "zh-Hans": the desktop shell catalog
# (resources/zh-Hans.json) is already in the package, but the bundled frontend
# (ion-dist) has no zh-Hans catalog and leaves it out of its locale lists. The
# frontend catalogs are fetched from claude.ai, the same files the web app loads.
import urllib.request, urllib.error, http.client, time

LANGUAGE_CODE = 'zh-Hans'
LANGUAGE_SOURCE = 'https://claude.ai/i18n/'
LANGUAGE_FILES = {  # target under resources/ion-dist/i18n -> required
    'zh-Hans.json': True,
    'dynamic/zh-Hans.json': False,
    'zh-Hans.overrides.json': False,
}
LOCALE_LIST = r'\["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID"\]'
LOCALE_LIST_MATCHES = 2  # verified on 2.31226.1.0: one shared bundle, two lists
LANGUAGE_NAME_ENTRY = r'"en-US":\{name:"English \(United States\)",localName:"English \(United States\)"\}'
LANGUAGE_NAME_REPLACEMENT = ('"en-US":{name:"English (United States)",localName:"English (United States)"},'
    '"zh-Hans":{name:"Chinese (Simplified)",localName:"中文（简体）"}')
BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36'

def add_zh_locale(text):
    return re.subn(LOCALE_LIST, lambda m: m[0][:-1] + ',"' + LANGUAGE_CODE + '"]', text)

def fetch_language(url):
    request = urllib.request.Request(url, headers={'User-Agent': BROWSER_UA, 'Accept': 'application/json'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            if exc.code == 404: return None
            if attempt == 2: raise
            time.sleep(attempt + 1)
        except (urllib.error.URLError, http.client.IncompleteRead, TimeoutError):
            if attempt == 2: raise
            time.sleep(attempt + 1)

def read_catalog(data, label):
    value = json.loads(data)
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        raise ValueError('Invalid language catalog: ' + label)
    return value

def merged_catalogs(resources, directory=None):
    """Merge the official zh-Hans frontend catalogs with this build's en-US ones by key.

    claude.ai may be newer than the bundled frontend: keys this build does not
    use are dropped and keys missing from the official catalog keep English.
    Returns ({target: catalog}, {target: sha256 of the source file}).
    """
    i18n = resources/'ion-dist/i18n'
    if not (resources/(LANGUAGE_CODE + '.json')).is_file():
        raise ValueError('This build has no official ' + LANGUAGE_CODE + ' desktop catalog; no files changed')
    if directory is None:
        log('Downloading official Simplified Chinese catalogs from ' + LANGUAGE_SOURCE + ' ...')
    sources = {}
    for target, required in LANGUAGE_FILES.items():
        if directory is not None:
            path = directory/target
            data = path.read_bytes() if path.is_file() else None
        else:
            try:
                data = fetch_language(LANGUAGE_SOURCE + target)
            except Exception as exc:
                raise ValueError('Cannot download ' + LANGUAGE_SOURCE + target + ' (' + str(exc) + '). '
                    'Use -LanguageDir with an offline copy or -NoLanguage to skip Chinese. No application files changed.') from exc
        if data is None:
            if required: raise ValueError('Official language catalog not found: ' + target + '. No application files changed.')
            continue
        sources[target] = data
    packs = {t: read_catalog(d, t) for t, d in sources.items()}
    if not packs['zh-Hans.json']: raise ValueError('Empty official language catalog: zh-Hans.json')
    base = packs['zh-Hans.json']
    result = {}
    english = read_catalog((i18n/'en-US.json').read_bytes(), 'en-US.json')
    result['zh-Hans.json'] = {k: base.get(k, v) for k, v in english.items()}
    dyn_en = i18n/'dynamic/en-US.json'
    if dyn_en.is_file():
        dyn = packs.get('dynamic/zh-Hans.json', {})
        result['dynamic/zh-Hans.json'] = {k: dyn.get(k, base.get(k, v)) for k, v in read_catalog(dyn_en.read_bytes(), 'dynamic/en-US.json').items()}
    result['zh-Hans.overrides.json'] = packs.get('zh-Hans.overrides.json', {})
    return {'ion-dist/i18n/' + t: c for t, c in result.items()}, {t: sha(d) for t, d in sources.items()}

# Never use tempfile.TemporaryFile/NamedTemporaryFile/mkstemp inside the Claude
# installation directory. On Windows, CPython's tempfile retries every
# PermissionError while os.access(dir, W_OK) is true, and os.access only checks
# the read-only attribute, not ACLs. In an ACL-protected WindowsApps folder each
# create is denied, so tempfile loops up to os.TMP_MAX (2147483647 on Windows)
# times and the script appears to hang for hours. These helpers make one create
# per candidate name and let PermissionError surface immediately.
_O_BINARY = getattr(os, 'O_BINARY', 0)

def create_exclusive(directory, prefix, attempts=100):
    for _ in range(attempts):
        name = os.path.join(str(directory), prefix + os.urandom(8).hex())
        try:
            fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | _O_BINARY, 0o600)
        except FileExistsError:
            continue
        return fd, pathlib.Path(name)
    raise FileExistsError('No usable staging file name found in ' + str(directory))

def probe_writable_dir(directory):
    fd, path = create_exclusive(directory, '.claude-patch-probe-')
    os.close(fd)
    path.unlink()

def sha_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(chunk), b''):
            h.update(b)
    return h.hexdigest()

def check_integrity(entry, data, name):
    integrity = entry.get('integrity')
    if not integrity:
        return
    if integrity.get('algorithm') != 'SHA256' or sha(data) != integrity['hash']:
        raise ValueError('ASAR hash mismatch: ' + name)
    bs = int(integrity['blockSize'])
    if bs <= 0:
        raise ValueError('Invalid block size')
    blocks = [sha(data[i:i + bs]) for i in range(0, len(data), bs)] or [sha(b'')]
    if blocks != integrity['blocks']:
        raise ValueError('ASAR block mismatch: ' + name)

def refresh_integrity(entry, data, name):
    if 'integrity' not in entry:
        return
    bs = int(entry['integrity'].get('blockSize', 4194304))
    if bs <= 0:
        raise ValueError('Invalid blockSize: ' + name)
    entry['integrity'] = {'algorithm': 'SHA256', 'hash': sha(data), 'blockSize': bs,
        'blocks': [sha(data[i:i + bs]) for i in range(0, len(data), bs)] or [sha(b'')]}

def load_asar_header(f):
    prefix = f.read(16)
    if len(prefix) < 16:
        raise ValueError('Invalid ASAR')
    size, header_size, payload_size, json_size = struct.unpack('<4I', prefix)
    if size != 4 or payload_size + 4 != header_size or json_size > payload_size - 4:
        raise ValueError('Unexpected ASAR pickle layout')
    hdr_bytes = f.read(json_size)
    if len(hdr_bytes) != json_size:
        raise ValueError('Truncated ASAR header')
    return json.loads(hdr_bytes), hdr_bytes, 8 + header_size

def collect_entries(hdr, base, fsize):
    out = []
    def walk(node, prefix=''):
        for name, entry in node.get('files', {}).items():
            full = prefix + name
            if 'files' in entry:
                walk(entry, full + '/')
            elif 'offset' in entry:
                offset, size = int(entry['offset']), int(entry['size'])
                if offset < 0 or size < 0 or base + offset + size > fsize:
                    raise ValueError('ASAR entry outside archive: ' + full)
                out.append((full, entry, offset, size))
    walk(hdr)
    out.sort(key=lambda t: t[2])
    return out

def apply_pre_patch(data, report):
    text = data.decode('utf8')
    text = patch_validator(text, 'preload gateway validator', report)
    text = patch_discovery_default(text, 'preload model discovery default true', report)
    text = patch_telemetry_defaults(text, 'preload', report)
    text = patch_browser_default(text, 'preload', report)
    text = patch_local_features(text, 'preload', report)
    text = patch_effective_telemetry(text, 'preload', report, startup=True)
    return text.encode('utf8')

PROGRESS_BYTES = 64 << 20

def stream_build_asar(source, body_tmp_path, report):
    """Validate, patch and rebuild the ASAR in a single streaming pass.

    Each packed file is read exactly once: its integrity is verified, patches
    are applied to the three target bundles, and the (possibly patched) bytes
    are appended to body_tmp_path. Peak memory is ~one file instead of ~3x
    the whole archive. Raises on any integrity or match-count problem; the
    real files stay untouched because everything goes to a temp file.
    """
    with open(source, 'rb') as f:
        fsize = os.fstat(f.fileno()).st_size
        hdr, hdr_bytes, base = load_asar_header(f)
        old_header_hash = sha(hdr_bytes)
        new_hdr = copy.deepcopy(hdr)
        new_entries = {}
        def walk(node, prefix=''):
            for name, entry in node.get('files', {}).items():
                full = prefix + name
                if 'files' in entry:
                    walk(entry, full + '/')
                elif 'offset' in entry:
                    new_entries[full] = entry
        walk(new_hdr)
        entries = collect_entries(hdr, base, fsize)
        total = len(entries)
        main_hit = None
        window_hit = None
        pre_hit = False
        patched_texts = {}
        with open(body_tmp_path, 'wb') as body:
            done_bytes = 0
            next_log = PROGRESS_BYTES
            for i, (full, entry, offset, size) in enumerate(entries, 1):
                f.seek(base + offset)
                data = f.read(size)
                if len(data) != size:
                    raise ValueError('Truncated ASAR data: ' + full)
                check_integrity(entry, data, full)
                new_data = data
                if full == '.vite/build/index.pre.js':
                    pre_hit = True
                    new_data = apply_pre_patch(data, report)
                    patched_texts[full] = new_data
                elif full.endswith('.js') and b'adminListObviatesDiscovery' in data:
                    if main_hit is not None:
                        raise ValueError('Main bundle does not match supported build')
                    main_hit = full
                    new_data = patch_main(data.decode('utf8'), report).encode('utf8')
                    patched_texts[full] = new_data
                elif '/main_window/' in full and full.endswith('.js') and b'function A(){' in data and b'requestMainMenuPopup' in data:
                    if window_hit is not None:
                        raise ValueError('Cannot uniquely identify local window menu; no files changed')
                    window_hit = full
                    new_data = patch_window_menu(data.decode('utf8'), report).encode('utf8')
                    patched_texts[full] = new_data
                new_entry = new_entries[full]
                new_entry['offset'] = str(body.tell())
                new_entry['size'] = len(new_data)
                if new_data is not data:
                    refresh_integrity(new_entry, new_data, full)
                body.write(new_data)
                done_bytes += size
                if done_bytes >= next_log or i == total:
                    log(f'  ... {i}/{total} files, {done_bytes >> 20} MB processed')
                    next_log += PROGRESS_BYTES
    if main_hit is None:
        raise ValueError('Main bundle does not match supported build')
    if window_hit is None:
        raise ValueError('Cannot uniquely identify local window menu; no files changed')
    if not pre_hit:
        raise ValueError('Preload bundle not found: .vite/build/index.pre.js')
    log(f'Source ASAR verified and rebuilt: {total} files')
    return {'header': new_hdr, 'old_header_hash': old_header_hash,
            'patched_texts': patched_texts, 'file_count': total}

def assemble_asar(new_hdr, body_tmp_path, final_path):
    jb = dump(new_hdr)
    pad = (-len(jb)) % 4
    payload = 4 + len(jb) + pad
    h = hashlib.sha256()
    with open(final_path, 'wb') as out:
        prefix = struct.pack('<4I', 4, 4 + payload, payload, len(jb))
        out.write(prefix)
        h.update(prefix)
        out.write(jb)
        h.update(jb)
        if pad:
            out.write(b'\0' * pad)
            h.update(b'\0' * pad)
        with open(body_tmp_path, 'rb') as body:
            for chunk in iter(lambda: body.read(1 << 20), b''):
                out.write(chunk)
                h.update(chunk)
    return h.hexdigest(), sha(jb)

def verify_asar(path, patched_names):
    with open(path, 'rb') as f:
        fsize = os.fstat(f.fileno()).st_size
        hdr, _, base = load_asar_header(f)
        entries = collect_entries(hdr, base, fsize)
        total = len(entries)
        done_bytes = 0
        next_log = PROGRESS_BYTES
        for i, (full, entry, offset, size) in enumerate(entries, 1):
            f.seek(base + offset)
            integrity = entry.get('integrity')
            if integrity and full in patched_names:
                data = f.read(size)
                if len(data) != size:
                    raise ValueError('Truncated ASAR data: ' + full)
                check_integrity(entry, data, full)
            elif integrity:
                # Streaming whole-file + per-block validation without loading
                # the full entry. Mirrors check_integrity's block contract:
                # ceil(size/blockSize) blocks, or a single empty block.
                bs = integrity.get('blockSize')
                blocks = integrity.get('blocks')
                if (integrity.get('algorithm') != 'SHA256' or type(bs) is not int
                        or bs <= 0 or type(blocks) is not list
                        or any(type(b) is not str for b in blocks)):
                    raise ValueError('ASAR integrity metadata invalid: ' + full)
                h = hashlib.sha256()
                bh = hashlib.sha256()
                in_block = 0
                bi = 0
                remaining = size
                while remaining:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        raise ValueError('Truncated ASAR data: ' + full)
                    h.update(chunk)
                    remaining -= len(chunk)
                    pos = 0
                    while pos < len(chunk):
                        take = min(bs - in_block, len(chunk) - pos)
                        bh.update(chunk[pos:pos + take])
                        in_block += take
                        pos += take
                        if in_block == bs:
                            if bi >= len(blocks) or bh.hexdigest() != blocks[bi]:
                                raise ValueError('ASAR block mismatch: ' + full)
                            bi += 1
                            bh = hashlib.sha256()
                            in_block = 0
                if in_block or not size:
                    if bi >= len(blocks) or bh.hexdigest() != blocks[bi]:
                        raise ValueError('ASAR block mismatch: ' + full)
                    bi += 1
                if bi != len(blocks) or h.hexdigest() != integrity.get('hash'):
                    raise ValueError('ASAR hash mismatch: ' + full)
            done_bytes += size
            if done_bytes >= next_log or i == total:
                log(f'  ... verified {i}/{total} files, {done_bytes >> 20} MB')
                next_log += PROGRESS_BYTES
    log(f'ASAR verified: {total} files')


def once(text, pattern, replacement, label, report, count=1):
    matches=list(re.finditer(pattern,text))
    if len(matches)!=count:
        raise ValueError(f'{label}: expected {count} match(es), got {len(matches)}; unsupported build')
    report.append({'patch':label,'matches':len(matches)})
    return re.sub(pattern,replacement,text)

def patch_validator(text,label,report):
    # Only the gateway/mantle validator, not shared checks for other providers.
    pat=r'function ([\w$]+)\(e\)\{return [\w$]+\(e\)\?\{ok:!0\}:\{ok:!1,reason:"expected a gateway model route referencing an Anthropic model[^"\n]*"\}\}'
    def repl(m):
        return 'function '+m[1]+'(e){return '+VALID_ID+'?{ok:!0}:{ok:!1,reason:"Model ID must be non-empty and contain no control characters"}}'
    return once(text,pat,repl,label,report)

def patch_discovery_default(text,label,report):
    pattern=r'(flatKey:"modelDiscoveryEnabled",readers:\["desktop","code"\],support:\{enabled:\{scopes:\["3p"\],availableInVersion:"1\.8089\.0"\},executionTarget:"desktop"\},default:)\{displayOnly:!0\}'
    return once(text,pattern,lambda m:m[1]+'!0',label,report)

def patch_telemetry_defaults(text,label,report):
    for key in ['disableEssentialTelemetry','disableNonessentialTelemetry']:
        pattern=r'(flatKey:"'+key+r'",readers:\["desktop","code"\],support:\{enabled:\{scopes:\["3p"\],availableInVersion:"1\.2581\.0"\}\},remotePolicy:\{default:!0,applyUnverified:!0\},failClosedValue:!0,title:[^\n]*?,default:)!1(?=,category:"telemetry")'
        text=once(text,pattern,lambda m:m[1]+'!0',label+' '+key+' default true',report)
        scopes=r'(flatKey:"'+key+r'",readers:\["desktop","code"\],support:\{enabled:\{scopes:)\["3p"\]'
        text=once(text,scopes,lambda m:m[1]+'["3p","1p"]',label+' '+key+' support 1p',report)
    for key in ['toolSearchEnabled','skipWebFetchPreflight']:
        pattern=r'(flatKey:"'+key+r'",readers:\["desktop","code"\],support:\{enabled:\{scopes:\["3p"\],availableInVersion:"[^"]+"\},executionTarget:"desktop"\},title:[^\n]*?,default:)(?:!1|\{displayOnly:!1\})(?=,category:"sandbox")'
        text=once(text,pattern,lambda m:m[1]+'!0',label+' '+key+' default true',report)
        pattern=r'(flatKey:"'+key+r'",readers:\["desktop","code"\],support:\{enabled:\{scopes:)\["3p"\]'
        text=once(text,pattern,lambda m:m[1]+'["3p","1p"]',label+' '+key+' support 1p',report)
    return text

def patch_browser_default(text,label,report):
    # Enable the local default, while preserving explicit false and org policy.
    pattern=r'(flatKey:"builtinBrowserEnabled",support:\{enabled:\{scopes:\["3p"\],availableInVersion:"2\.2553\.0"\},executionTarget:"desktop"\},title:[^\n]*?,default:)!1(?=,remotePolicy:)'
    return once(text,pattern,lambda m:m[1]+'!0',label+' browser default true',report)

def patch_local_features(text,label,report):
    # 2.31226 uses rule descriptors, shared by main and startup bundles.
    # Browser rules still follow builtinBrowserEnabled and its policy check.
    cu={'enabled':True,'batchOnly':False,'teachModeEnabled':True,
        'clipboardPasteMultiline':True,'coordinateMode':'pixels',
        'dispatchCuGrantTtlMs':1800000,'hideBeforeAction':True,
        'mouseAnimation':True,'pixelValidation':True,'autoTargetDisplay':True,
        'clipboardGuard':True,'maskFailClosed':True,'adaptiveResolution':True}
    extra={str(key):{'rule':'forced','value':True} for key in (4293378213,36693946,40173473)}
    extra['1291166712']={'rule':'forced','value':cu}
    pattern=r'17519066:\{rule:"forcedFor",group:"builtinBrowser",value:!0\}'
    return once(text,pattern,lambda m:dump(extra).decode()[1:-1]+','+m[0],
        label+' CU local feature rules',report)

def patch_effective_telemetry(text,label,report,startup=False):
    # These accessors run after scope filtering and before Sentry startup.
    # Leave third-party opt-outs intact; force both blocks for first-party mode.
    name,reader,snapshot,predicate=('V1','B1','O1','i0') if startup else ('K','sUe','Vu','bu')
    pattern=r'function '+name+r'\(e\)\{return '+reader+r'\('+snapshot+r'\(\),e\)\}'
    replacement='function '+name+'(e){let t='+reader+'('+snapshot+'(),e);return '+predicate+'(t)?t:{...t,telemetry:{...t.telemetry,disableEssential:!0,disableNonessential:!0}}}'
    return once(text,pattern,replacement,label+' 1p effective telemetry disabled',report)

def patch_offline_menu(text,report):
    # Reserve a local title-bar strip above the remote WebContentsView. A DOM
    # z-index alone cannot put the shell button above a native child view.
    old='y.setBounds({x:0,y:0,width:t.width,height:t.height-0}),n.width!==t.width||n.height!==t.height-0'
    new='y.setBounds({x:0,y:40,width:t.width,height:Math.max(0,t.height-40)}),n.y!==40||n.width!==t.width||n.height!==Math.max(0,t.height-40)'
    text=once(text,re.escape(old),lambda m:new,'persistent local menu viewport',report)
    old='submenu:[tpi(),...npi(),...rpi(),...Kfi(),'
    new='submenu:[{label:X().formatMessage({defaultMessage:"Configure Third-Party Inference\\u2026",id:"9GRz7bC+rr"}),click:()=>ega()},tpi(),...npi(),...rpi(),...Kfi(),'
    return once(text,re.escape(old),lambda m:new,'local third-party setup menu entry',report)

def patch_window_menu(text,report):
    old='n&&(0,m.jsxs)(m.Fragment,{children:[(0,m.jsx)("div",{className:"nc-no-drag absolute top-2 left-2 z-[60]"'
    new='(0,m.jsxs)(m.Fragment,{children:[(0,m.jsx)("div",{className:"nc-no-drag absolute top-1 left-2 z-[60]"'
    text=once(text,re.escape(old),lambda m:new,'local menu visible without load error',report)
    text=once(text,re.escape('onMouseDown:n.offlineGame?'),lambda m:'onMouseDown:n?.offlineGame?',
        'local menu handles absent load error',report)
    text=once(text,re.escape('(0,m.jsx)(T,{details:n,onRefresh:D,onRestart:O})'),
        lambda m:'n&&(0,m.jsx)(T,{details:n,onRefresh:D,onRestart:O})',
        'load error overlay remains conditional',report)
    return text

def patch_main(text,report):
    text=patch_offline_menu(text,report)
    text=patch_validator(text,'main gateway validator',report)
    text=patch_discovery_default(text,'main model discovery default true',report)
    text=patch_telemetry_defaults(text,'main',report)
    text=patch_browser_default(text,'main',report)
    # Keep provider compatibility detection (unpinned), and use host tool search
    # for 1p instead of the legacy third-party beta-header path.
    text=once(text,r'!t\.thirdParty\|\|!e\.workspace\.toolSearchEnabled\?"off":e\.inference\?\.provider==="gateway"',
        '!e.workspace.toolSearchEnabled?"off":!t.thirdParty?"host":e.inference?.provider==="gateway"',
        'tool search enabled for 1p and 3p sessions',report)
    text=once(text,r'\.\.\.t\.thirdParty&&e\.workspace\.skipWebFetchPreflight===!0&&\{skipWebFetchPreflight:!0\}',
        '...e.workspace.skipWebFetchPreflight===!0&&{skipWebFetchPreflight:!0}',
        'WebFetch skip preflight passed to 1p and 3p sessions',report)
    text=patch_effective_telemetry(text,'main',report)
    text=once(text,r'\.\.\.r&&\{DISABLE_GROWTHBOOK:"1",',
        '...!r&&{DISABLE_TELEMETRY:"1",DISABLE_ERROR_REPORTING:"1",ENABLE_TOOL_SEARCH:c==="host"?"force":"false"},...r&&{DISABLE_GROWTHBOOK:"1",',
        '1p Code telemetry and host tool search environment',report)
    text=once(text,r'return!So\(t\.id\)&&!n\?\[\]:\[',
        lambda m:'return!('+re.sub(r'\be\b','t.id',VALID_ID)+')?[]:[',
        'gateway discovery filter',report)
    text=once(text,r'\{ok:!0,models:T2t\(w2t\(c\)\),\.\.\.d&&\{partial:!0\}\}',
        '{ok:!0,models:Array.from(new Map(c.map(e=>[e.id,e])).values()),...d&&{partial:!0}}',
        'gateway discovery deduplication',report)
    text=once(text,r'adminListObviatesDiscovery\(\)\{let e=this\.creds\.models;return!!e\?\.length&&!e\.some\(\(e=>xtn\.some\(\(t=>t===e\.name\.toLowerCase\(\)\)\)\)\)\}',
        'adminListObviatesDiscovery(){return!1}', 'gateway discover with manual list',report)
    text=once(text,r'else a=r\?\?\[\];return i&&',
        'else a=r??[];if((e==="gateway"||e==="mantle")&&r?.length){let t=new Set(a.map(e=>e.id));a=[...a,...r.filter(e=>!t.has(e.id))]}return i&&',
        'gateway merge configured and discovered models',report)
    text=patch_local_features(text,'main',report)
    text=once(text,r'dramatic_shrimp:void 0','dramatic_shrimp:"available"',
        'local 3p remote-tools availability',report)
    # Native browser getter, CU org/HIPAA gates, OS permissions, grants and
    # network policies are deliberately retained.
    return text

def backup_file(app,path,backup,inventory):
    rel=path.relative_to(app).as_posix()
    original=backup/'files'/rel
    if rel not in inventory:
        if path.exists():
            original.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,original)
            inventory[rel]={'existed':True,'sha256':sha_file(original)}
        else: inventory[rel]={'existed':False}

def syntax_check(node, data, tempdir, name):
    if not node: raise ValueError('Node.js is required for JavaScript syntax verification')
    p=tempdir/(re.sub(r'[^\w.-]','_',name)+'.mjs');p.write_bytes(data)
    result=subprocess.run([node,'--check',str(p)],capture_output=True,text=True,encoding='utf8',errors='replace')
    if result.returncode: raise ValueError('JavaScript syntax failed: '+name+'\n'+result.stderr[:1500])

def restore(app,backup):
    inv=json.loads((backup/'inventory.json').read_text(encoding='utf8'))
    # Validate the entire snapshot before changing any destination.
    if not inv: raise ValueError('Backup inventory is empty')
    for rel,meta in inv.items():
        if not (app/rel).resolve().is_relative_to(app.resolve()): raise ValueError('Invalid backup path')
        src=backup/'files'/rel
        if not src.resolve().is_relative_to((backup/'files').resolve()): raise ValueError('Invalid backup source')
        if meta['existed'] and sha_file(src)!=meta['sha256']: raise ValueError('Backup corrupted: '+rel)
    for rel,meta in inv.items():
        dest=app/rel
        if not dest.resolve().is_relative_to(app.resolve()): raise ValueError('Invalid backup path')
        if meta['existed']:
            src=backup/'files'/rel
            if sha_file(src)!=meta['sha256']: raise ValueError('Backup corrupted: '+rel)
            dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
        elif dest.exists(): dest.unlink()
    for rel,meta in inv.items():
        dest=app/rel
        if meta['existed']:
            if sha_file(dest)!=meta['sha256']: raise ValueError('Restore verification failed: '+rel)
        elif dest.exists(): raise ValueError('Added file was not removed: '+rel)
    report_path=app.parent/'patch-report.json'
    if report_path.exists():
        report=json.loads(report_path.read_text(encoding='utf8'))
        report['resourcesRestored']=True
        report_path.write_bytes(dump(report))
    log('Original application resources restored. User data was not changed.')

def main():
    p=argparse.ArgumentParser();p.add_argument('--app',required=True)
    p.add_argument('--node',required=True);p.add_argument('--check-only',action='store_true');p.add_argument('--restore',action='store_true');p.add_argument('--skip-syntax-check',action='store_true')
    p.add_argument('--language',default='');p.add_argument('--no-language',action='store_true')
    args=p.parse_args();app=pathlib.Path(args.app).resolve()
    if not (app/'resources/app.asar').is_file():raise ValueError('Not a Claude app directory')
    manifest=app.parent/'AppxManifest.xml'
    detected_version='unknown'
    if manifest.exists():
        identity=ET.parse(manifest).getroot().find('{*}Identity')
        detected_version=identity.attrib['Version']
        if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+',detected_version): raise ValueError('Invalid package version')
    if not args.restore and detected_version!=VERSION:
        raise ValueError(f'Unsupported Claude version: {detected_version}; expected {VERSION}. No application files changed.')
    backup=app.parent/'patch-backup'
    legacy_backup=app.parent/('patch-backup-'+detected_version)
    if not backup.exists() and legacy_backup.exists():
        if args.check_only: backup=legacy_backup
        else: legacy_backup.rename(backup)
    if not args.check_only:
        # Check directory creation and existing-file writes before changing resources.
        log('Checking write access to the Claude installation...')
        try:
            targets=[app/'claude.exe',app/'resources/app.asar',* (app/'resources/ion-dist/assets/v1').glob('*.js')]
            i18n=app/'resources/ion-dist/i18n'
            for directory in {app.parent,app/'resources',*([i18n] if i18n.is_dir() else []),*(path.parent for path in targets)}:
                probe_writable_dir(directory)
            for path in targets:
                with path.open('r+b'): pass
            backup.mkdir(parents=True,exist_ok=True)
        except PermissionError as exc:
            raise PermissionError('Claude installation is not writable. Run PowerShell as administrator with the same Windows user. WindowsApps may still deny writes; no application resources have been changed. Target: '+str(app)) from exc
    if args.restore:restore(app,backup);return
    # Fingerprint of the patch engine itself: the repeat-run shortcut below may
    # only trigger when the current engine would produce the same build, so an
    # edited script can never be silently skipped.
    engine_id=sha(pathlib.Path(__file__).read_bytes())
    inventory_path=backup/'inventory.json'
    inv=json.loads(inventory_path.read_text(encoding='utf8')) if inventory_path.exists() else {}
    # Language catalogs are prepared before anything else so a download failure
    # changes nothing. English baselines come from the pre-patch backup when present.
    use_language=not args.no_language
    language_writes={};language_report={};language_sources=None
    if use_language:
        resources=app/'resources'
        packs,language_sources=merged_catalogs(resources,pathlib.Path(args.language).resolve() if args.language else None)
        for target,pack in packs.items():
            language_writes[resources/target]=dump(pack)
            language_report[target]={'keys':len(pack),'withChinese':sum(bool(re.search(r'[\u3400-\u9fff]',x)) for x in pack.values())}
        log('Language catalogs prepared: '+', '.join(f"{k} ({v['withChinese']}/{v['keys']} Chinese)" for k,v in language_report.items()))
    if not args.check_only and not args.restore:
        # Skip quickly when the installed files exactly match this patch build.
        prev={}
        prev_path=app.parent/'patch-report.json'
        if prev_path.exists():
            try: prev=json.loads(prev_path.read_text(encoding='utf8'))
            except Exception: prev={}
        fa=prev.get('frontendAsset') or {}
        fa_path=app/fa['path'] if isinstance(fa.get('path'),str) else None
        prev_extra=prev.get('writtenFiles') if isinstance(prev.get('writtenFiles'),dict) else {}
        def extra_matches():
            # Every other written file (locale-list assets, catalogs) must match too,
            # and the catalogs must equal what this run would write.
            for rel,digest in prev_extra.items():
                path=app/rel
                if not path.resolve().is_relative_to(app.resolve()) or not path.is_file() or sha_file(path)!=digest: return False
            for path,data in language_writes.items():
                if prev_extra.get(path.relative_to(app).as_posix())!=sha(data): return False
            return bool(prev.get('language'))==use_language
        exe_path=app/'claude.exe'
        asar_path=app/'resources/app.asar'
        if prev: log('Checking whether the installed files already match this patch build...')
        if (prev and not prev.get('resourcesRestored')
                and prev.get('engineSHA256')==engine_id
                and not (not args.skip_syntax_check and prev.get('syntaxCheckSkipped'))
                and isinstance(prev.get('exeSHA256'),str)
                and prev['exeSHA256']==sha_file(exe_path)
                and isinstance(prev.get('asarSHA256'),str)
                and prev['asarSHA256']==sha_file(asar_path)
                and fa_path is not None and fa_path.resolve().is_relative_to(app.resolve())
                and isinstance(fa.get('sha256'),str) and fa['sha256']==sha_file(fa_path)
                and extra_matches()):
            log('Already patched: installed files match this patch build. Nothing to do.')
            return
    baseline_asar=backup/'files/resources/app.asar'
    source=baseline_asar if baseline_asar.exists() else app/'resources/app.asar'
    report=[]
    with tempfile.TemporaryDirectory(prefix='claude-patch-') as td:
        td=pathlib.Path(td)
        body_tmp=td/'body.bin'
        final_tmp=td/'app.asar'
        log('Validating source ASAR and rebuilding in a single streaming pass (reads the full archive once; may take a few minutes)...')
        built=stream_build_asar(source,body_tmp,report)
        old_hash=built['old_header_hash']
        patched_names=set(built['patched_texts'])
        writes={}
        assets=app/'resources/ion-dist/assets/v1'
        def pristine(path):
            rel=path.relative_to(app).as_posix();b=backup/'files'/rel
            return (b if b.exists() else path).read_text(encoding='utf8')
        asset_texts={p:pristine(p) for p in assets.glob('*.js')}
        front=[p for p,t in asset_texts.items() if 'flatKey:"modelDiscoveryEnabled"' in t and 'flatKey:"disableEssentialTelemetry"' in t]
        if len(front)!=1:raise ValueError('Cannot uniquely identify compatible frontend structures; no files changed')
        front_text=patch_validator(pristine(front[0]),'frontend gateway validator',report)
        front_text=patch_discovery_default(front_text,'frontend model discovery default true',report)
        front_text=patch_telemetry_defaults(front_text,'frontend',report)
        writes[front[0]]=patch_browser_default(front_text,'frontend',report).encode('utf8')
        front_rel=front[0].relative_to(app).as_posix()
        if use_language:
            def current(path): return writes[path].decode('utf8') if path in writes else asset_texts[path]
            locale_assets=[p for p in asset_texts if re.search(LOCALE_LIST,asset_texts[p])]
            if len(locale_assets)!=1:raise ValueError(f'Cannot uniquely identify the frontend supported-locale lists (found {len(locale_assets)} files); no files changed')
            text,hits=add_zh_locale(current(locale_assets[0]))
            if hits!=LOCALE_LIST_MATCHES:raise ValueError(f'frontend supported locales: expected {LOCALE_LIST_MATCHES} matches, found {hits}; no files changed')
            writes[locale_assets[0]]=text.encode('utf8')
            report.append({'patch':'frontend supported locales','matches':hits})
            name_assets=[p for p in asset_texts if re.search(LANGUAGE_NAME_ENTRY,asset_texts[p])]
            if len(name_assets)!=1:raise ValueError('Cannot uniquely identify the language name table; no files changed')
            writes[name_assets[0]]=once(current(name_assets[0]),LANGUAGE_NAME_ENTRY,LANGUAGE_NAME_REPLACEMENT,'language menu',report).encode('utf8')
            writes.update(language_writes)
        if args.skip_syntax_check:
            log('WARNING: JavaScript syntax verification skipped (--skip-syntax-check).')
        else:
            for n,b in built['patched_texts'].items():syntax_check(args.node,b,td,n)
            for path,b in writes.items():
                if path.suffix=='.js':syntax_check(args.node,b,td,path.name)
        log('Assembling rebuilt ASAR...')
        asar_sha256,new_hash=assemble_asar(built['header'],body_tmp,final_tmp)
        log('Verifying rebuilt ASAR...')
        verify_asar(final_tmp,patched_names)
        exe_path=app/'claude.exe';bexe=backup/'files/claude.exe'
        exe=(bexe if bexe.exists() else exe_path).read_bytes()
        hits=exe.count(old_hash.encode('ascii'))
        if hits!=1:raise ValueError(f'EXE embedded ASAR hash: expected 1 occurrence, found {hits}')
        patched_exe=exe.replace(old_hash.encode('ascii'),new_hash.encode('ascii'))
        report_obj={'detectedVersion':detected_version,'testedBaselineVersion':VERSION,'compatibilityMode':'structure-checked','patches':report,
            'originalHeaderSHA256':old_hash,'newHeaderSHA256':new_hash,
            'asarSHA256':asar_sha256,'exeSHA256':sha(patched_exe),
            'signedExeSignatureInvalidated':True,'runtimeTested':False,'resourcesRestored':False,
            'streamingBuild':True,'syntaxCheckSkipped':args.skip_syntax_check,
            'engineSHA256':engine_id,
            'frontendAsset':{'path':front_rel,'sha256':sha(writes[front[0]])},
            'writtenFiles':{p.relative_to(app).as_posix():sha(b) for p,b in writes.items() if p!=front[0]},
            'language':language_report,'languageCode':LANGUAGE_CODE if use_language else None,
            'languageSource':(args.language or LANGUAGE_SOURCE) if use_language else None,
            'languageSourceSHA256':language_sources}
        if args.check_only:
            log(json.dumps(report_obj,ensure_ascii=False,indent=2));log('CHECK ONLY: no application files changed.');return
        # A previous patch may have written files this run will not rewrite (another
        # language code, or Chinese before a -NoLanguage run). Overwriting the rest
        # would leave those behind, so require a clean restore first.
        prev_written={}
        prev_report_path=app.parent/'patch-report.json'
        if prev_report_path.exists():
            try:
                prev_report=json.loads(prev_report_path.read_text(encoding='utf8'))
                if not prev_report.get('resourcesRestored') and isinstance(prev_report.get('writtenFiles'),dict):prev_written=prev_report['writtenFiles']
            except Exception: prev_written={}
        planned={p.relative_to(app).as_posix() for p in writes}|{front_rel}
        stale=sorted({rel for rel in prev_written if rel not in planned}
            |{rel for rel,meta in inv.items() if not meta.get('existed') and rel not in planned and (app/rel).exists()})
        if stale:
            raise ValueError('Files from a previous patch would be left behind ('+', '.join(stale[:5])+('...' if len(stale)>5 else '')+'). Run -Restore first, then patch again. No application files changed.')
        writes[exe_path]=patched_exe
        for path in list(writes)+[app/'resources/app.asar']:backup_file(app,path,backup,inv)
        inventory_path.write_bytes(dump(inv))
        for rel,meta in inv.items():
            if meta['existed'] and sha_file(backup/'files'/rel)!=meta['sha256']:
                raise ValueError('Backup verification failed before modification: '+rel)
        log('Pre-modification backup verified: '+str(backup))
        # Prepare all files before replacing any originals. Roll back the full set
        # on any failed write, including external JS.
        staged=[];replaced=False
        try:
            for path,data in writes.items():
                path.parent.mkdir(parents=True,exist_ok=True)
                fd,temp=create_exclusive(path.parent,path.name+'.patch-');staged.append((temp,path))
                with os.fdopen(fd,'wb') as handle:handle.write(data)
            asar_path=app/'resources/app.asar'
            fd,asar_stage=create_exclusive(asar_path.parent,asar_path.name+'.patch-');os.close(fd)
            staged.append((asar_stage,asar_path))
            shutil.copyfile(final_tmp,asar_stage)
            for temp,path in staged:
                os.replace(temp,path);replaced=True
            log('Verifying installed ASAR...')
            verify_asar(asar_path,patched_names)
            if new_hash.encode() not in exe_path.read_bytes():raise ValueError('EXE header hash verification failed')
            (app.parent/'patch-report.json').write_bytes(dump(report_obj))
        except BaseException:
            if replaced:restore(app,backup)
            raise
        finally:
            for temp,path in staged:
                if temp.exists():temp.unlink()
    log('Patch complete. Original executable signature is no longer valid; ASAR integrity is retained.')
    log('Backup: '+str(backup));log('Report: '+str(app.parent/'patch-report.json'))

if __name__=='__main__':
    try:main()
    except Exception as exc:log('ERROR: '+str(exc));sys.exit(1)

'@
    if (-not $CheckOnly) {
        if (-not $Restore) {
            # Read-only compatibility gate before any ownership/ACL change, so an
            # unsupported build never leaves the install with altered permissions.
            if ($backend -notmatch "(?m)^VERSION = '([^']+)'") { throw 'Cannot read the supported version from the patch engine.' }
            $supportedVersion = $Matches[1]
            [xml]$manifestXml = Get-Content -LiteralPath (Join-Path $InstallDir 'AppxManifest.xml') -Raw
            $installedVersion = [string]$manifestXml.Package.Identity.Version
            if ($installedVersion -ne $supportedVersion) { throw "Unsupported Claude version: $installedVersion; expected $supportedVersion. No permissions or application files changed." }
        }
        # Only stop Claude once the build is known to be supported.
        Stop-TargetClaude $AppDir
        if (-not (Test-InstallWritable $InstallDir $AppDir)) {
            if ($NoAclChange) { Write-Warning 'Installation is not writable and -NoAclChange was given; the engine will report the failure.' }
            else { Grant-InstallWriteAccess $InstallDir }
        }
    }
    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ('claude-patch-' + [Guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($tempScript,$backend,[Text.UTF8Encoding]::new($false))
    $oldEncoding = $env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        $engineArgs = @($tempScript,'--app',$AppDir,'--node',$NodePath)
        if ($CheckOnly) { $engineArgs += '--check-only' }
        if ($Restore) { $engineArgs += '--restore' }
        if ($skipSyntax) { $engineArgs += '--skip-syntax-check' }
        if ($NoLanguage) { $engineArgs += '--no-language' }
        elseif ($LanguageDir) { $engineArgs += @('--language',$LanguageDir) }
        & $PythonPath @engineArgs
        if ($LASTEXITCODE -ne 0) { throw 'Patch engine failed. See the diagnostic above.' }
    } finally {
        $env:PYTHONIOENCODING = $oldEncoding
        if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force }
    }
    if ($Restore) {
        if (-not $NoAclChange -and -not (Restore-InstallAcl $InstallDir)) { $exitCode = 1 }
    }
    elseif (-not $CheckOnly) {
        Info 'Current Claude installation patched. Start Claude and create a new session for session settings to take effect.'
        if (-not $NoLanguage) { Info 'Select 中文（简体） in Claude Settings / Language.' }
        Info ('Restore resources: powershell -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Restore -InstallDir "' + $InstallDir + '"')
    }
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
    # Permissions changed by this run but the patch did not complete (the engine
    # rolls back its own file writes): put the original ACL back.
    # On -Restore the restore contract includes the ACL, so revert it even when
    # the resource restore failed.
    if (-not $NoAclChange -and (Test-Path variable:AppDir) -and ($script:AclGrantedThisRun -or $Restore)) {
        Info 'Run did not complete; reverting permission changes to the original ACL.'
        try { $null = Restore-InstallAcl $InstallDir } catch { Write-Host ('ERROR: ACL revert failed: ' + $_.Exception.Message) -ForegroundColor Red }
    }
}
if ($ElevatedChild) { $null = Read-Host 'Press Enter to close this window' }
exit $exitCode
