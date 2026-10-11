# Claude Desktop compatible builds: Gateway models + CU/Browser.

[CmdletBinding()]
param(
    [string]$MsixPath = '',
    [string]$InstallDir = '',
    [string]$PythonPath = '',
    [string]$NodePath = '',
    [switch]$CheckOnly,
    [switch]$PatchOnly,
    [switch]$Activate,
    [Alias('RestoreOriginal')][switch]$Restore,
    [switch]$NoLaunch,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Info([string]$Message) { Write-Host ('==> ' + $Message) -ForegroundColor Cyan }
function Resolve-Runtime([string]$Given,[string]$Name,[string[]]$Fallbacks) {
    if ($Given) { return (Resolve-Path -LiteralPath $Given).Path }
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($candidate in $Fallbacks) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "$Name was not found. Supply its executable path explicitly."
}
function Stop-TargetClaude([string]$TargetApp) {
    $targetExe = [IO.Path]::GetFullPath((Join-Path $TargetApp 'claude.exe'))
    Get-Process -Name claude -ErrorAction SilentlyContinue | ForEach-Object {
        try { $processExe = $_.Path } catch { $processExe = $null }
        if ($processExe -and [string]::Equals($processExe,$targetExe,[StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $_.Id -Force
        }
    }
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
function Copy-DirectoryTree([string]$Source,[string]$Destination) {
    # Robocopy supports long Windows paths without requiring PowerShell 5.1
    # Copy-Item to traverse Chromium cache filenames. Do not use /256.
    $copyLog = Join-Path ([IO.Path]::GetTempPath()) ('claude-copy-' + [Guid]::NewGuid().ToString('N') + '.log')
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:2 /W:1 /NP /NFL /NDL /NJH /NJS "/LOG:$copyLog" | Out-Null
    $copyExit = $LASTEXITCODE
    if ($copyExit -ge 8) { throw "Directory backup/copy failed (robocopy exit $copyExit). Current registration has not been removed during backup. See $copyLog" }
    if (Test-Path -LiteralPath $copyLog) { Remove-Item -LiteralPath $copyLog -Force }
}
function Restore-PackageData([string]$Snapshot,[string]$Family) {
    if (-not (Test-Path -LiteralPath $Snapshot)) { return }
    $dataRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $Family
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    Copy-DirectoryTree $Snapshot $dataRoot
}

try {
    if ($Restore -and ($CheckOnly -or $Activate)) { throw '-Restore cannot be combined with -CheckOnly/-Activate.' }
    if ($CheckOnly -and $Activate) { throw '-CheckOnly cannot activate an application.' }
    if (-not $InstallDir) {
        $InstallDir = Join-Path $PSScriptRoot 'ClaudeDesktop-Patched'
        # Continue an existing layout instead of abandoning its original backup.
        $legacyLayout = Join-Path $PSScriptRoot 'ClaudeDesktop-Patched-2.16120.0.0'
        if (-not (Test-Path -LiteralPath $InstallDir) -and (Test-Path -LiteralPath (Join-Path $legacyLayout 'AppxManifest.xml'))) {
            $InstallDir = $legacyLayout
        }
    }
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    if ($InstallDir -match '(?i)\\WindowsApps(?:\\|$)') { throw 'Choose a directory outside WindowsApps.' }
    if ($InstallDir -eq [IO.Path]::GetPathRoot($InstallDir)) { throw 'InstallDir cannot be a drive root.' }
    $PythonPath = Resolve-Runtime $PythonPath 'python.exe' @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe')
    )
    if ($Restore) { $NodePath = 'unused-for-restore' }
    else { $NodePath = Resolve-Runtime $NodePath 'node.exe' @('D:\nodejs\node.exe') }
    $installed = @(Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue)
    $matching = @($installed | Sort-Object Version -Descending | Select-Object -First 1)
    $AppDir = Join-Path $InstallDir 'app'
    if ($Restore -or $PatchOnly) {
        Check-Manifest $InstallDir
        if (-not $CheckOnly) { Stop-TargetClaude $AppDir }
    } elseif ($CheckOnly -and -not $MsixPath -and -not (Test-Path -LiteralPath $AppDir)) {
        if ($matching.Count -ne 1) { throw 'Claude is not installed.' }
        Check-Manifest $matching[0].InstallLocation
        $AppDir = Join-Path $matching[0].InstallLocation 'app'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $AppDir 'resources\app.asar'))) {
        if (Test-Path -LiteralPath $InstallDir) { throw 'InstallDir already exists without complete application files. Choose a new directory.' }
        if ($MsixPath) {
            $MsixPath = (Resolve-Path -LiteralPath $MsixPath).Path
            Info "Extracting MSIX to $InstallDir"
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            # Validate ZIP destination paths before extracting untrusted archives.
            $zip = [IO.Compression.ZipFile]::OpenRead($MsixPath)
            try {
                $prefix = $InstallDir.TrimEnd('\') + '\'
                foreach ($entry in $zip.Entries) {
                    $dest = [IO.Path]::GetFullPath((Join-Path $InstallDir $entry.FullName))
                    if (-not $dest.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'MSIX contains an unsafe entry path.' }
                }
            } finally { $zip.Dispose() }
            [IO.Compression.ZipFile]::ExtractToDirectory($MsixPath,$InstallDir)
        } else {
            if ($matching.Count -ne 1) { throw 'Install Claude or supply -MsixPath.' }
            $sourceRoot = $matching[0].InstallLocation
            Check-Manifest $sourceRoot
            Info "Copying installed package to $InstallDir (current install stays active)"
            New-Item -ItemType Directory -Path $InstallDir | Out-Null
            Copy-DirectoryTree $sourceRoot $InstallDir
        }
        Check-Manifest $InstallDir
    } else {
        Check-Manifest $InstallDir
        if (-not $CheckOnly) { Stop-TargetClaude $AppDir }
    }

    # Backend is embedded to keep the patch engine in a single PS1.
    $backend = @'
"""Claude Desktop 2.31226.1.0 patch engine. Standard library only.

Never writes to WindowsApps. PowerShell wrapper owns package registration.
"""
import argparse, copy, hashlib, json, os, pathlib, re, shutil, struct, subprocess, sys, tempfile, xml.etree.ElementTree as ET

VERSION = '2.31226.1.0'
VALID_ID = r'typeof e==="string"&&e.trim().length>0&&!/[\x00-\x1f\x7f-\x9f]/.test(e)'

def sha(b): return hashlib.sha256(b).hexdigest()
def dump(o): return json.dumps(o, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
def log(s): print(s, flush=True)

def read_asar(path):
    raw = path.read_bytes()
    if len(raw) < 16: raise ValueError('Invalid ASAR')
    size, header_size, payload_size, json_size = struct.unpack_from('<4I', raw)
    if size != 4 or payload_size + 4 != header_size or json_size > payload_size - 4:
        raise ValueError('Unexpected ASAR pickle layout')
    hdr_bytes = raw[16:16+json_size]
    hdr = json.loads(hdr_bytes)
    base = 8 + header_size
    files = {}
    def walk(node, prefix=''):
        for name, entry in node.get('files', {}).items():
            full = prefix + name
            if 'files' in entry: walk(entry, full + '/')
            elif 'offset' in entry:
                offset, size = int(entry['offset']), int(entry['size'])
                if offset < 0 or size < 0 or base+offset+size > len(raw):
                    raise ValueError('ASAR entry outside archive: '+full)
                files[full] = (entry, raw[base+offset:base+offset+size])
    walk(hdr)
    return hdr, files, sha(hdr_bytes)

def validate_asar(path):
    hdr, files, hh = read_asar(path)
    for name,(entry,data) in files.items():
        integrity = entry.get('integrity')
        if not integrity: continue
        if integrity.get('algorithm') != 'SHA256' or sha(data) != integrity['hash']:
            raise ValueError('ASAR hash mismatch: '+name)
        bs = int(integrity['blockSize'])
        if bs <= 0: raise ValueError('Invalid block size')
        blocks = [sha(data[i:i+bs]) for i in range(0,len(data),bs)] or [sha(b'')]
        if blocks != integrity['blocks']: raise ValueError('ASAR block mismatch: '+name)
    return len(files), hh

def build_asar(hdr, files, changes):
    hdr = copy.deepcopy(hdr)
    entries = {}
    def walk(node,prefix=''):
        for n,e in node.get('files',{}).items():
            full=prefix+n
            if 'files' in e: walk(e,full+'/')
            elif 'offset' in e: entries[full]=e
    walk(hdr)
    body=bytearray()
    for name,(old,data) in sorted(files.items(),key=lambda x:int(x[1][0]['offset'])):
        data=changes.get(name,data)
        e=entries[name]; e['offset']=str(len(body)); e['size']=len(data)
        if 'integrity' in e:
            bs=int(e['integrity'].get('blockSize',4194304))
            if bs<=0: raise ValueError('Invalid blockSize: '+name)
            e['integrity']={'algorithm':'SHA256','hash':sha(data),'blockSize':bs,
                'blocks':[sha(data[i:i+bs]) for i in range(0,len(data),bs)] or [sha(b'')]}
        body.extend(data)
    jb=dump(hdr); pad=(-len(jb))%4
    payload=4+len(jb)+pad
    return struct.pack('<4I',4,4+payload,payload,len(jb))+jb+b'\0'*pad+body, sha(jb)

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
            inventory[rel]={'existed':True,'sha256':sha(original.read_bytes())}
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
        if meta['existed'] and sha(src.read_bytes())!=meta['sha256']: raise ValueError('Backup corrupted: '+rel)
    for rel,meta in inv.items():
        dest=app/rel
        if not dest.resolve().is_relative_to(app.resolve()): raise ValueError('Invalid backup path')
        if meta['existed']:
            src=backup/'files'/rel
            if sha(src.read_bytes())!=meta['sha256']: raise ValueError('Backup corrupted: '+rel)
            dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest)
        elif dest.exists(): dest.unlink()
    for rel,meta in inv.items():
        dest=app/rel
        if meta['existed']:
            if sha(dest.read_bytes())!=meta['sha256']: raise ValueError('Restore verification failed: '+rel)
        elif dest.exists(): raise ValueError('Added file was not removed: '+rel)
    report_path=app.parent/'patch-report.json'
    if report_path.exists():
        report=json.loads(report_path.read_text(encoding='utf8'))
        report['resourcesRestored']=True
        report_path.write_bytes(dump(report))
    log('Original application resources restored. User data was not changed.')

def main():
    p=argparse.ArgumentParser();p.add_argument('--app',required=True)
    p.add_argument('--node',required=True);p.add_argument('--check-only',action='store_true');p.add_argument('--restore',action='store_true')
    args=p.parse_args();app=pathlib.Path(args.app).resolve()
    if 'windowsapps' in str(app).lower() and not args.check_only: raise ValueError('Refusing to modify WindowsApps')
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
    if not args.check_only:backup.mkdir(parents=True,exist_ok=True)
    if args.restore:restore(app,backup);return
    inventory_path=backup/'inventory.json'
    inv=json.loads(inventory_path.read_text(encoding='utf8')) if inventory_path.exists() else {}
    baseline_asar=backup/'files/resources/app.asar'
    source=baseline_asar if baseline_asar.exists() else app/'resources/app.asar'
    count,old_hash=validate_asar(source);log(f'Original ASAR verified: {count} packed files')
    hdr,files,_=read_asar(source);changes={};report=[]
    main_names=[n for n,(e,b) in files.items() if n.endswith('.js') and b'adminListObviatesDiscovery' in b]
    if len(main_names)!=1:raise ValueError('Main bundle does not match supported build')
    main_name=main_names[0]
    changes[main_name]=patch_main(files[main_name][1].decode('utf8'),report).encode('utf8')
    window_names=[n for n,(e,b) in files.items() if '/main_window/' in n and n.endswith('.js') and b'function A(){' in b and b'requestMainMenuPopup' in b]
    if len(window_names)!=1:raise ValueError('Cannot uniquely identify local window menu; no files changed')
    window_name=window_names[0]
    changes[window_name]=patch_window_menu(files[window_name][1].decode('utf8'),report).encode('utf8')
    pre='.vite/build/index.pre.js'
    pre_text=patch_validator(files[pre][1].decode('utf8'),'preload gateway validator',report)
    pre_text=patch_discovery_default(pre_text,'preload model discovery default true',report)
    pre_text=patch_telemetry_defaults(pre_text,'preload',report)
    pre_text=patch_browser_default(pre_text,'preload',report)
    pre_text=patch_local_features(pre_text,'preload',report)
    pre_text=patch_effective_telemetry(pre_text,'preload',report,startup=True)
    changes[pre]=pre_text.encode('utf8')
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
    new_asar,new_hash=build_asar(hdr,files,changes)
    exe_path=app/'claude.exe';bexe=backup/'files/claude.exe'
    exe=(bexe if bexe.exists() else exe_path).read_bytes()
    hits=exe.count(old_hash.encode('ascii'))
    if hits!=1:raise ValueError(f'EXE embedded ASAR hash: expected 1 occurrence, found {hits}')
    patched_exe=exe.replace(old_hash.encode('ascii'),new_hash.encode('ascii'))
    with tempfile.TemporaryDirectory(prefix='claude-patch-') as td:
        td=pathlib.Path(td)
        for n,b in changes.items():syntax_check(args.node,b,td,n)
        for path,b in writes.items():
            if path.suffix=='.js':syntax_check(args.node,b,td,path.name)
        test_asar=td/'app.asar';test_asar.write_bytes(new_asar);validate_asar(test_asar)
    report_obj={'detectedVersion':detected_version,'testedBaselineVersion':VERSION,'compatibilityMode':'structure-checked','patches':report,
        'originalHeaderSHA256':old_hash,'newHeaderSHA256':new_hash,
        'asarSHA256':sha(new_asar),'exeSHA256':sha(patched_exe),
        'signedExeSignatureInvalidated':True,'runtimeTested':False,'resourcesRestored':False}
    if args.check_only:
        log(json.dumps(report_obj,ensure_ascii=False,indent=2));log('CHECK ONLY: no application files changed.');return
    writes[app/'resources/app.asar']=new_asar;writes[exe_path]=patched_exe
    for path in writes:backup_file(app,path,backup,inv)
    inventory_path.write_bytes(dump(inv))
    for rel,meta in inv.items():
        if meta['existed'] and sha((backup/'files'/rel).read_bytes())!=meta['sha256']:
            raise ValueError('Backup verification failed before modification: '+rel)
    log('Pre-modification backup verified: '+str(backup))
    # Prepare all files before replacing any originals. Roll back the full set
    # on any failed write, including external JS.
    staged=[]
    try:
        for path,data in writes.items():
            path.parent.mkdir(parents=True,exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=path.parent,prefix=path.name+'.patch-',delete=False) as handle:
                temp=pathlib.Path(handle.name);staged.append((temp,path));handle.write(data)
        for temp,path in staged:os.replace(temp,path)
        validate_asar(app/'resources/app.asar')
        if new_hash.encode() not in exe_path.read_bytes():raise ValueError('EXE header hash verification failed')
        (app.parent/'patch-report.json').write_bytes(dump(report_obj))
    except BaseException:
        restore(app,backup);raise
    finally:
        for temp,path in staged:
            if temp.exists():temp.unlink()
    log('Patch complete. Original executable signature is no longer valid; ASAR integrity is retained.')
    log('Backup: '+str(backup));log('Report: '+str(app.parent/'patch-report.json'))

if __name__=='__main__':
    try:main()
    except Exception as exc:log('ERROR: '+str(exc));sys.exit(1)

'@
    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ('claude-patch-' + [Guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($tempScript,$backend,[Text.UTF8Encoding]::new($false))
    $oldEncoding = $env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        $engineArgs = @($tempScript,'--app',$AppDir,'--node',$NodePath)
        if ($CheckOnly) { $engineArgs += '--check-only' }
        if ($Restore) { $engineArgs += '--restore' }
        & $PythonPath @engineArgs
        if ($LASTEXITCODE -ne 0) { throw 'Patch engine failed. No package registration was changed.' }
    } finally {
        $env:PYTHONIOENCODING = $oldEncoding
        if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force }
    }
    if ($CheckOnly -or $Restore) { return }

    if ($Activate) {
        $developer = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
        if (-not $developer -or -not $developer.PSObject.Properties['AllowDevelopmentWithoutDevLicense'] -or $developer.AllowDevelopmentWithoutDevLicense -ne 1) {
            throw 'Patched files are ready. Enable Windows Developer Mode, then rerun with -PatchOnly -Activate. Current MSIX was not removed.'
        }
        if (-not $Yes) {
            $answer = Read-Host 'Replace the current Claude package registration with the patched development layout? [y/N]'
            if ($answer -notmatch '^[yY]$') { Info 'Patched copy kept. Current package registration was not changed.'; return }
        }
        # Finish all patching and checks before changing the active registration.
        $registered = @(Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue)
        $alreadyLoose = @($registered | Where-Object { $_.InstallLocation -eq $InstallDir })
        if ($alreadyLoose.Count -eq 0) {
            if ($registered.Count -gt 1) { throw 'Multiple Claude packages exist; resolve package ownership before activation.' }
            # Packaged services require elevation even with Developer Mode on.
            # Check before removing the current registration so failure is safe.
            [xml]$activationManifest = Get-Content -LiteralPath (Join-Path $InstallDir 'AppxManifest.xml') -Raw
            $serviceCapabilities = @($activationManifest.SelectNodes("//*[local-name()='Capability' and (@Name='localSystemServices' or @Name='packagedServices')]"))
            $activationPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
            if ($serviceCapabilities.Count -gt 0 -and -not $activationPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'This Claude package contains Windows services. Run PowerShell as administrator for activation. Patched files are ready; current registration has not been removed.'
            }
            $activationBackup = Join-Path $InstallDir ('registration-backup\' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $activationBackup -Force | Out-Null
            $previous = @()
            foreach ($pkg in $registered) {
                Stop-TargetClaude (Join-Path $pkg.InstallLocation 'app')
                $originalCopy = Join-Path $activationBackup 'original-package'
                New-Item -ItemType Directory -Path $originalCopy -Force | Out-Null
                Info 'Backing up the previous application layout before activation'
                Copy-DirectoryTree $pkg.InstallLocation $originalCopy
                $snapshot = Join-Path $activationBackup 'user-data'
                New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
                $currentData = Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $pkg.PackageFamilyName
                foreach ($folder in @('LocalCache','LocalState','RoamingState','AppData')) {
                    $dataFolder = Join-Path $currentData $folder
                    if (Test-Path -LiteralPath $dataFolder) {
                        Copy-DirectoryTree $dataFolder (Join-Path $snapshot $folder)
                    }
                }
                $previous += [pscustomobject]@{PackageFullName=$pkg.PackageFullName;Family=$pkg.PackageFamilyName;OriginalLayout=$originalCopy;DataSnapshot=$snapshot}
            }
            $activation = [ordered]@{PreviousPackage=$previous;NewLayout=$InstallDir;At=(Get-Date).ToString('o')}
            $activation | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $InstallDir 'activation-record.json') -Encoding UTF8
            foreach ($pkg in $registered) {
                Info "Removing current-user registration: $($pkg.PackageFullName)"
                if ($pkg.IsDevelopmentMode) { Remove-AppxPackage -Package $pkg.PackageFullName -PreserveApplicationData }
                else { Remove-AppxPackage -Package $pkg.PackageFullName }
            }
            try {
                Add-AppxPackage -Register (Join-Path $InstallDir 'AppxManifest.xml') -ErrorAction Stop
                foreach ($prior in $previous) { Restore-PackageData $prior.DataSnapshot $prior.Family }
            }
            catch {
                $activationError = $_.Exception.Message
                # If the new layout registered but data restoration failed,
                # remove that registration before rolling back the layout.
                Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.InstallLocation -eq $InstallDir } | ForEach-Object {
                    Remove-AppxPackage -Package $_.PackageFullName -PreserveApplicationData
                }
                foreach ($old in $previous) {
                    $oldManifest = Join-Path $old.OriginalLayout 'AppxManifest.xml'
                    if (Test-Path -LiteralPath $oldManifest) {
                        try { Add-AppxPackage -Register $oldManifest -ErrorAction Stop; Restore-PackageData $old.DataSnapshot $old.Family; Info 'Previous application layout and data restored.' }
                        catch { Write-Warning 'Previous package files are unavailable or could not be registered. Reinstall the official package; see activation-record.json.' }
                    } else { Write-Warning 'Previous package was removed by Windows. Reinstall the official package if needed.' }
                }
                throw "Development-layout registration failed: $activationError. Patched copy and resource backups remain."
            }
        }
        if (-not $NoLaunch) {
            $active = Get-AppxPackage -Name Claude | Where-Object { $_.InstallLocation -eq $InstallDir } | Select-Object -First 1
            if (-not $active) { throw 'Patched package was not registered.' }
            Start-Process ('shell:AppsFolder\' + $active.PackageFamilyName + '!Claude')
        }
        Info 'Activated. Restart Claude and create a new session for session settings to take effect.'
    } else {
        Info 'Patched copy is ready. Current installed Claude remains active.'
        Info 'To activate: rerun this script with -PatchOnly -Activate (Developer Mode required).'
    }
    Info ('Restore resources: powershell -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Restore -InstallDir "' + $InstallDir + '"')
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
