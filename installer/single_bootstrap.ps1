$ErrorActionPreference='Stop'
$exitCode=1
$scratch=$null
try {
    $self=[IO.File]::ReadAllText($env:ESGKR_SELF,[Text.Encoding]::UTF8)
    $data=($self -split '(?m)^#DATA-BEGIN\r?$',2)[1]
    $bytes=[Convert]::FromBase64String($data.Trim())
    $alg=[Security.Cryptography.SHA256]::Create()
    try {$hash=[BitConverter]::ToString($alg.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}
    finally {$alg.Dispose()}
    if($hash -ne '__PAYLOAD_SHA256__'){throw '내장 패치 데이터가 손상되었습니다. 파일을 다시 내려받으세요.'}
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $scratch=Join-Path $tempRoot ('ESGKR-v090-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($scratch)
    [IO.File]::SetAttributes($scratch,[IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $memory=New-Object IO.MemoryStream(,$bytes)
    $archive=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach($entry in $archive.Entries){
            $dest=[IO.Path]::GetFullPath((Join-Path $scratch $entry.FullName))
            if(-not $dest.StartsWith($scratch+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe package entry.'}
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            $input=$entry.Open()
            $output=[IO.File]::Create($dest)
            try {$input.CopyTo($output)} finally {$output.Dispose();$input.Dispose()}
        }
    } finally {$archive.Dispose();$memory.Dispose()}
    $automated=$env:ESGKR_TEST_TARGET
    if($automated){
        if(-not (Test-Path -LiteralPath (Join-Path $automated '.esgkr-test-target'))){throw 'Test marker missing.'}
        $mode=$env:ESGKR_TEST_ACTION
    } else {
        Write-Host ''
        Write-Host 'Eiyu Senki Gold 한국어 패치 v0.9.0'
        Write-Host '1. 패치 설치'
        Write-Host '2. 설치 전 상태로 복구'
        Write-Host '3. 사용법 / 패치 범위 보기'
        Write-Host '4. 글꼴 라이선스 보기'
        Write-Host '0. 종료'
        $choice=Read-Host '번호를 선택하세요 (Enter: 설치)'
        $mode=switch($choice){'2'{'Restore'} '3'{'Readme'} '4'{'License'} '0'{'Exit'} ''{'Install'} '1'{'Install'} default{throw '잘못된 선택입니다.'}}
    }
    if($mode -eq 'Readme' -or $mode -eq 'License'){
        $names=if($mode -eq 'Readme'){@('README.md')}else{@('FONT-NOTICE.txt','OFL.txt')}
        foreach($name in $names){Write-Host ([IO.File]::ReadAllText((Join-Path $scratch $name),[Text.Encoding]::UTF8))}
        $exitCode=0
    } elseif($mode -eq 'Exit'){$exitCode=0}
    else {
        $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $scratch 'install.ps1'))
        if($automated){
            $argsList+=@('-GamePath',$automated,'-TestMode')
            if($mode -eq 'Verify'){$argsList+='-VerifyOnly';$mode='Install'}
        }
        if($mode -notin @('Install','Restore')){throw 'Invalid mode.'}
        $argsList+=@('-Mode',$mode)
        & (Join-Path $PSHOME 'powershell.exe') @argsList
        $exitCode=$LASTEXITCODE
    }
} catch {Write-Host ('오류: '+$_.Exception.Message) -ForegroundColor Red}
finally {
    if($scratch -and [IO.Directory]::Exists($scratch)){
        $resolved=[IO.Path]::GetFullPath($scratch)
        $expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\ESGKR-v090-'
        if($resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)){
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
exit $exitCode
