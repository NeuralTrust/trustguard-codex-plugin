# Bootstrap for the TrustGuard Codex plugin (Windows).
#
# Mirror of trustguard-hook.sh: prefers a PATH-installed trustguard-codex,
# otherwise installs the pinned release for this arch into
# %USERPROFILE%\.trustguard\bin in the background, verifying its SHA-256
# against the table below. Every bootstrap failure fails open.

param([switch]$InstallOnly)

$Version = '0.1.0'

$Sha256 = @{
    'amd64' = ''
    'arm64' = ''
}

$Stdin = if ($InstallOnly) { $null } else { [Console]::In.ReadLine() }

function Invoke-Hook([string]$Exe) {
    $out = $Stdin | & $Exe hook
    if ($null -ne $out) { Write-Output $out }
    exit $LASTEXITCODE
}

function Exit-FailOpen([string]$Message) {
    [Console]::Error.WriteLine("trustguard-codex bootstrap: $Message - allowing without evaluation")
    Write-Output '{}'
    exit 0
}

function Install-Binary([string]$Url, [string]$Target, [string]$WantSha) {
    $tmp = "$Target.download.$PID"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp -TimeoutSec 300
        $gotSha = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLowerInvariant()
        if ($gotSha -ne $WantSha.ToLowerInvariant()) { throw "checksum mismatch (got $gotSha, want $WantSha)" }
        Move-Item -Force $tmp $Target
    } catch {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp
        [Console]::Error.WriteLine("trustguard-codex bootstrap: install failed: $($_.Exception.Message)")
    }
}

try {
    $onPath = Get-Command 'trustguard-codex' -ErrorAction SilentlyContinue
    if ($onPath -and -not $InstallOnly) { Invoke-Hook $onPath.Source }

    $binDir = if ($env:TRUSTGUARD_CODEX_BIN_DIR) { $env:TRUSTGUARD_CODEX_BIN_DIR } else { Join-Path $env:USERPROFILE '.trustguard\bin' }
    $baseUrl = if ($env:TRUSTGUARD_CODEX_DOWNLOAD_BASE) { $env:TRUSTGUARD_CODEX_DOWNLOAD_BASE } else { 'https://github.com/NeuralTrust/trustguard-codex-plugin/releases/download' }

    $bin = Join-Path $binDir "trustguard-codex-$Version.exe"
    if ((Test-Path $bin) -and -not $InstallOnly) { Invoke-Hook $bin }

    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default { Exit-FailOpen "unsupported arch $($env:PROCESSOR_ARCHITECTURE); install trustguard-codex manually" }
    }
    $wantSha = $Sha256[$arch]
    if (-not $wantSha) {
        Exit-FailOpen "no pinned checksum for windows/$arch (release $Version not published yet?); install trustguard-codex manually"
    }

    $url = "$baseUrl/v$Version/trustguard-codex_${Version}_windows_$arch.exe"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $lock = Join-Path $binDir "install-codex-$Version.lock"

    if ($InstallOnly) {
        Install-Binary $url $bin $wantSha
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $lock
        exit 0
    }

    if ((Test-Path $lock) -and ((Get-Item $lock).CreationTime -lt (Get-Date).AddMinutes(-10))) {
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $lock
    }
    if (-not (Test-Path $lock)) {
        New-Item -ItemType Directory -Path $lock -ErrorAction SilentlyContinue | Out-Null
        Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-InstallOnly'
        )
    }
    Exit-FailOpen "trustguard-codex $Version not installed yet; fetching it in the background"
} catch {
    Exit-FailOpen "unexpected error: $($_.Exception.Message)"
}
