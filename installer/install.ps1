param(
    [ValidateSet('Install','Restore')][string]$Mode='Install',
    [string]$GamePath,
    [switch]$VerifyOnly,
    [switch]$TestMode,
    [int]$TestFailAfter=-1
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
function Hash([string]$p) {
    $stream=[IO.File]::OpenRead($p);$algorithm=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally {$stream.Dispose();$algorithm.Dispose()}
}
function SafePath([string]$root,[string]$rel) {
    $r=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
    $p=[IO.Path]::GetFullPath((Join-Path $r $rel))
    if(-not $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe relative path.'}
    return $p
}
function Parent([string]$p) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)) }
function SaveJson($data,[string]$p) { $data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $p -Encoding UTF8 }
function AddGameCandidate([string]$path) {
    if([string]::IsNullOrWhiteSpace($path)){return}
    try {
        $expanded=[Environment]::ExpandEnvironmentVariables($path.Trim().Trim('"'))
        $full=[IO.Path]::GetFullPath($expanded).TrimEnd('\')
        if($full -match '(?i)\\_korean_patch_backup(?:\\|$)'){return}
        if((Test-Path -LiteralPath (Join-Path $full 'EiyuSenkiGold.exe')) -and $script:candidateSeen.Add($full)){
            [void]$script:candidatePaths.Add($full)
        }
    } catch {}
}
function AddCommonRoot([string]$root) {
    if([string]::IsNullOrWhiteSpace($root)){return}
    AddGameCandidate $root
    AddGameCandidate (Join-Path $root 'Eiyu Senki Gold')
    AddGameCandidate (Join-Path $root 'Games\Eiyu Senki Gold')
    AddGameCandidate (Join-Path $root 'Steam\steamapps\common\Eiyu Senki Gold')
    AddGameCandidate (Join-Path $root 'SteamLibrary\steamapps\common\Eiyu Senki Gold')
}
function SelectSupportedGame($manifest) {
    $exe=$manifest.files | Where-Object path -eq 'EiyuSenkiGold.exe' | Select-Object -First 1
    foreach($candidate in $script:candidatePaths){
        try {
            if($TestMode -and -not (Test-Path -LiteralPath (Join-Path $candidate '.esgkr-test-target'))){continue}
            $digest=Hash (Join-Path $candidate 'EiyuSenkiGold.exe')
            if($digest -eq $exe.source_sha256 -or $digest -eq $exe.target_sha256){return $candidate}
        } catch {}
    }
    return $null
}
function FindGame($manifest) {
    $script:candidatePaths=New-Object 'System.Collections.Generic.List[string]'
    $script:candidateSeen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # Highest priority: BAT location and current directory.
    AddGameCandidate $env:ESGKR_LAUNCHER_DIR
    AddGameCandidate ([Environment]::CurrentDirectory)
    if(-not $TestMode){
        try {
            $saved=Get-ItemProperty -LiteralPath 'HKCU:\Software\EiyuSenkiGoldKoreanPatch' -Name GamePath
            AddGameCandidate ([string]$saved.GamePath)
        } catch {}
    }
    $userRoots=@(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        $env:USERPROFILE
    )
    try {
        $shell=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $downloads=$shell.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}']
        if($null -ne $downloads){$userRoots+=,[Environment]::ExpandEnvironmentVariables([string]$downloads.Value)}
    } catch {}
    foreach($root in $userRoots){AddCommonRoot $root}
    foreach($root in @($env:SystemDrive+'\Games',$env:ProgramFiles,${env:ProgramFiles(x86)})){AddCommonRoot $root}
    # Installed-program records are faster and safer than scanning entire drives.
    foreach($uninstall in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
        if(-not (Test-Path -LiteralPath $uninstall)){continue}
        foreach($key in Get-ChildItem -LiteralPath $uninstall -ErrorAction SilentlyContinue){
            try {
                $entry=Get-ItemProperty -LiteralPath $key.PSPath
                if(([string]$entry.DisplayName) -match '(?i)Eiyu\s*Senki.*Gold|英雄戦姫.*GOLD'){
                    AddGameCandidate ([string]$entry.InstallLocation)
                    if($entry.DisplayIcon){AddGameCandidate ([IO.Path]::GetDirectoryName(([string]$entry.DisplayIcon).Trim('"')))}
                }
            } catch {}
        }
    }
    # Steam install and additional library locations.
    $steamRoots=@()
    foreach($steamKey in @('HKCU:\Software\Valve\Steam','HKLM:\Software\WOW6432Node\Valve\Steam')){
        try {
            $entry=Get-ItemProperty -LiteralPath $steamKey
            foreach($name in @('SteamPath','InstallPath')){
                $prop=$entry.PSObject.Properties[$name]
                if($null -ne $prop -and $prop.Value){$steamRoots+=,[string]$prop.Value}
            }
        } catch {}
    }
    foreach($steam in $steamRoots){
        AddGameCandidate (Join-Path $steam 'steamapps\common\Eiyu Senki Gold')
        $vdf=Join-Path $steam 'steamapps\libraryfolders.vdf'
        if(Test-Path -LiteralPath $vdf){
            foreach($line in Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue){
                if($line -match '^\s*"path"\s*"([^"]+)"'){
                    $library=$matches[1].Replace('\\','\')
                    AddGameCandidate (Join-Path $library 'steamapps\common\Eiyu Senki Gold')
                }
            }
        }
    }
    $supported=SelectSupportedGame $manifest
    if($supported){return $supported}
    # Final fallback: locate the game anywhere on connected local drives.
    # 'where /r' is substantially faster than recursive PowerShell enumeration.
    $scanRoots=@()
    if($TestMode -and $env:ESGKR_TEST_SCAN_ROOT){
        $scanRoots+=,[IO.Path]::GetFullPath($env:ESGKR_TEST_SCAN_ROOT)
    } else {
        foreach($drive in [IO.DriveInfo]::GetDrives()){
            try {
                if($drive.IsReady -and $drive.DriveType -in @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)){
                    $scanRoots+=,$drive.RootDirectory.FullName
                }
            } catch {}
        }
    }
    $where=Join-Path $env:SystemRoot 'System32\where.exe'
    foreach($root in $scanRoots){
        Write-Host "게임 자동 검색 중: $root"
        try {
            $found=@(& $where /r $root 'EiyuSenkiGold.exe' 2>$null)
            foreach($exePath in $found){
                if(Test-Path -LiteralPath $exePath -PathType Leaf){AddGameCandidate ([IO.Path]::GetDirectoryName($exePath))}
            }
        } catch {}
        $supported=SelectSupportedGame $manifest
        if($supported){return $supported}
    }
    if($script:candidatePaths.Count){throw '게임 실행 파일은 찾았지만 지원하는 원본 또는 v0.9.0 파일이 아닙니다.'}
    throw '연결된 로컬 드라이브에서 지원하는 Eiyu Senki Gold를 찾지 못했습니다.'
}
function Closed {
    if(Get-Process -Name EiyuSenkiGold -ErrorAction SilentlyContinue){throw '게임을 완전히 종료한 뒤 다시 실행해 주세요.'}
}
function NotifyFonts {
    if(-not $TestMode){
        [UIntPtr]$result=[UIntPtr]::Zero
        [void][ESGDelta]::SendMessageTimeout([IntPtr]0xffff,0x1D,[UIntPtr]::Zero,$null,2,1000,[ref]$result)
    }
}
function RestoreState($state,[string]$backup,[bool]$checkCurrent) {
    # Refuse to undo files changed by the user after installation.
    if($checkCurrent){
        foreach($f in $state.files){
            $dest=SafePath $game $f.path
            if(-not (Test-Path -LiteralPath $dest) -or (Hash $dest) -ne $f.target_sha256){throw "설치 후 변경된 파일이 있습니다: $($f.path)"}
        }
    }
    foreach($f in $state.files){
        if($f.existed -and (Hash (SafePath $backup ('files/'+$f.path))) -ne $f.previous_sha256){throw "Backup damaged: $($f.path)"}
    }
    foreach($f in $state.files){
        $dest=SafePath $game $f.path
        if($f.existed){Copy-Item -LiteralPath (SafePath $backup ('files/'+$f.path)) -Destination $dest -Force}
        elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
    }
    foreach($f in $state.fonts){
        $properties=Get-ItemProperty -LiteralPath $reg
        $current=$properties.PSObject.Properties[$f.registryName]
        if($checkCurrent -and $null -ne $current -and $current.Value -ne $f.destination){continue}
        if(-not $TestMode){[void][ESGDelta]::RemoveFontResourceEx($f.destination,0,[IntPtr]::Zero)}
        if($f.previous){
            New-ItemProperty -LiteralPath $reg -Name $f.registryName -Value $f.previous -PropertyType String -Force | Out-Null
            if(-not $TestMode -and (Test-Path -LiteralPath $f.previous)){[void][ESGDelta]::AddFontResourceEx($f.previous,0,[IntPtr]::Zero)}
        } else {Remove-ItemProperty -LiteralPath $reg -Name $f.registryName -ErrorAction SilentlyContinue}
        if(-not $f.existed -and (Test-Path -LiteralPath $f.destination) -and (Hash $f.destination) -eq $f.sha256){Remove-Item -LiteralPath $f.destination -Force}
    }
    NotifyFonts
}
try {
    $m=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not $GamePath){
        $GamePath=FindGame $m
    }
    $game=(Resolve-Path -LiteralPath $GamePath).Path
    if(-not (Test-Path -LiteralPath (Join-Path $game 'EiyuSenkiGold.exe'))){throw '게임 실행 파일이 없는 폴더입니다.'}
    if($TestMode -and -not (Test-Path -LiteralPath (Join-Path $game '.esgkr-test-target'))){throw 'Test marker missing.'}
    if(-not $TestMode -and $TestFailAfter -ge 0){throw 'Failure injection requires test mode.'}
    Closed
    Add-Type -Path (Join-Path $PSScriptRoot 'Delta.cs')
    $reg='HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $fontRoot=Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if($TestMode){$reg='HKCU:\Software\ESGKRInstallerTests\Fonts';$fontRoot=Join-Path $game '_testfonts'}
    Write-Host "게임 폴더 자동 인식: $game"
    if($Mode -eq 'Restore'){
        $candidates=@(Get-ChildItem -LiteralPath (Join-Path $game '_korean_patch_backup') -Directory | Where-Object Name -Like 'v0.9.0_*' | Sort-Object Name -Descending)
        $chosen=$null
        foreach($c in $candidates){
            $sp=Join-Path $c.FullName 'state.json'
            if(Test-Path -LiteralPath $sp){$s=Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json;if($s.status -eq 'complete'){$chosen=$c;$state=$s;break}}
        }
        if(-not $chosen){throw '복구할 v0.9.0 설치 백업이 없습니다.'}
        RestoreState $state $chosen.FullName $true
        $state.status='restored';SaveJson $state (Join-Path $chosen.FullName 'state.json')
        Write-Host '설치 직전 상태로 복구했습니다. 세이브와 한글 이름 정보는 유지했습니다.'
        exit 0
    }
    $pending=@()
    # Complete preflight before touching installed files or fonts.
    foreach($f in $m.files){
        $payload=SafePath $PSScriptRoot $f.payload
        if((Hash $payload) -ne $f.payload_sha256){throw "패치 파일 손상: $($f.payload)"}
        $dest=SafePath $game $f.path
        $exists=Test-Path -LiteralPath $dest
        $h=if($exists){Hash $dest}else{$null}
        if($h -eq $f.target_sha256){continue}
        if($h -ne $f.source_sha256){throw "지원하지 않는 버전 또는 다른 수정 파일입니다: $($f.path). 원본 게임을 사용해 주세요."}
        $pending+=,$f
    }
    foreach($f in $m.fonts){if((Hash (SafePath $PSScriptRoot ('fonts/'+$f.filename))) -ne $f.sha256){throw "폰트 파일 손상: $($f.filename)"}}
    $stage=Join-Path $game ('_esgkr_stage_'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    foreach($f in $pending){
        $src=if($f.source_sha256){SafePath $game $f.path}else{$null}
        $dst=SafePath $stage $f.path;Parent $dst
        [ESGDelta]::Apply($src,(SafePath $PSScriptRoot $f.payload),$dst,[long]$f.size)
        if((Hash $dst) -ne $f.target_sha256){throw "패치 재구성 검증 실패: $($f.path)"}
    }
    if($VerifyOnly){Write-Host "검증 통과: $($m.files.Count)개 파일, $($pending.Count)개 재구성. 실제 설치는 하지 않았습니다.";exit 0}
    Closed
    $backup=Join-Path $game ('_korean_patch_backup\v0.9.0_'+(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    [void][IO.Directory]::CreateDirectory($backup)
    $state=[ordered]@{version='0.9.0';status='prepared';files=@();fonts=@()}
    foreach($f in $pending){
        $dst=SafePath $game $f.path;$exists=Test-Path -LiteralPath $dst
        if($exists){
            if((Hash $dst) -ne $f.source_sha256){throw 'Game changed during build.'}
            $saved=SafePath $backup ('files/'+$f.path);Parent $saved
            Copy-Item -LiteralPath $dst -Destination $saved
            if((Hash $saved) -ne $f.source_sha256){throw 'Backup verification failed.'}
        }
        $state.files+=@{path=$f.path;existed=$exists;previous_sha256=$f.source_sha256;target_sha256=$f.target_sha256}
    }
    [void][IO.Directory]::CreateDirectory($fontRoot)
    if(-not (Test-Path -LiteralPath $reg)){New-Item -Path $reg -Force | Out-Null}
    foreach($f in $m.fonts){
        $name=$f.family+' (TrueType)'
        $properties=Get-ItemProperty -LiteralPath $reg
        $prop=$properties.PSObject.Properties[$name]
        $prev=if($null -ne $prop){[string]$prop.Value}else{$null}
        $dest=Join-Path $fontRoot ('ESGKR-v090-'+$f.filename)
        $exists=Test-Path -LiteralPath $dest
        if($exists -and (Hash $dest) -ne $f.sha256){throw "Font destination changed: $dest"}
        if($prev -eq $dest -and $exists){continue}
        $state.fonts+=@{registryName=$name;previous=$prev;destination=$dest;existed=$exists;sha256=$f.sha256;filename=$f.filename}
    }
    SaveJson $state (Join-Path $backup 'state.json')
    try {
        $n=0
        foreach($f in $pending){
            Copy-Item -LiteralPath (SafePath $stage $f.path) -Destination (SafePath $game $f.path) -Force
            if((Hash (SafePath $game $f.path)) -ne $f.target_sha256){throw 'Installed hash mismatch.'}
            $n++
            if($TestMode -and $n -eq $TestFailAfter){throw 'Injected install failure'}
        }
        foreach($f in $state.fonts){
            if(-not $f.existed){Copy-Item -LiteralPath (SafePath $PSScriptRoot ('fonts/'+$f.filename)) -Destination $f.destination}
            if(-not $TestMode -and $f.previous){[void][ESGDelta]::RemoveFontResourceEx($f.previous,0,[IntPtr]::Zero)}
            New-ItemProperty -LiteralPath $reg -Name $f.registryName -Value $f.destination -PropertyType String -Force | Out-Null
            if(-not $TestMode -and [ESGDelta]::AddFontResourceEx($f.destination,0,[IntPtr]::Zero) -lt 1){throw 'Font load failed.'}
        }
        NotifyFonts
        $state.status='complete';SaveJson $state (Join-Path $backup 'state.json')
        if(-not $TestMode){
            if(-not (Test-Path -LiteralPath 'HKCU:\Software\EiyuSenkiGoldKoreanPatch')){New-Item -Path 'HKCU:\Software\EiyuSenkiGoldKoreanPatch' -Force | Out-Null}
            Set-ItemProperty -LiteralPath 'HKCU:\Software\EiyuSenkiGoldKoreanPatch' -Name GamePath -Value $game
        }
    } catch {
        $installError=$_
        RestoreState ([pscustomobject]$state) $backup $false
        $state.status='rolled_back';SaveJson $state (Join-Path $backup 'state.json')
        throw $installError
    }
    Write-Host "v0.9.0 설치 완료. 게임을 실행하세요. 백업: $backup"
    exit 0
} catch {
    Write-Host ('오류: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    # Only delete this invocation's uniquely named staging directory, inside the selected game.
    if((Get-Variable stage -ErrorAction SilentlyContinue) -and $stage -and (Test-Path -LiteralPath $stage)){
        $resolved=[IO.Path]::GetFullPath($stage)
        $prefix=[IO.Path]::GetFullPath($game).TrimEnd('\')+'\_esgkr_stage_'
        if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
}
