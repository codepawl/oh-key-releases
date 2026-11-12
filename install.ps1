# Installs the latest oh-key release (the tray app, oh-key.exe) from codepawl/oh-key-releases,
# after checking its SHA-256 against SHA256SUMS.txt. The command line tool is in the release zip.
#   .\install.ps1                    install into %LOCALAPPDATA%\Programs\oh-key and start the app
#   .\install.ps1 -StartAtSignIn     also start the app every time you sign in
#
# No administrator rights are needed: everything goes into your own profile.
#
param(
    [switch]$StartAtSignIn
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 may still offer TLS 1.0 and 1.1 by default.
$protocols = [Net.SecurityProtocolType]::Tls12
try { $protocols = $protocols -bor [Net.SecurityProtocolType]'Tls13' } catch { }
[Net.ServicePointManager]::SecurityProtocol = $protocols

$installFolder = Join-Path $env:LOCALAPPDATA 'Programs\oh-key'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Stop-RunningApp {
    # StartsWith, not -like: a user name with [ ] would be read as a wildcard.
    $ownFolders = @("$installFolder\", "$env:ProgramFiles\oh-key\")
    Get-Process -Name 'oh-key' -ErrorAction SilentlyContinue |
        Where-Object {
            $processPath = $_.Path
            $processPath -and ($ownFolders | Where-Object { $processPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# Points the Run value at the installed exe. An existing value is refreshed even without the
# switch, so the path never goes stale when the exe moves.
function Set-StartAtSignIn {
    $command = '"' + (Join-Path $installFolder 'oh-key.exe') + '"'
    Set-ItemProperty -Path $runKey -Name 'oh-key' -Value $command
}

# The tag the latest release points to, read once from the redirect, so the exe and its checksum
# list come from the same release even if a new one is published in between.
function Get-LatestTag {
    $request = [Net.HttpWebRequest]::Create('https://github.com/codepawl/oh-key-releases/releases/latest')
    $request.AllowAutoRedirect = $false
    $response = $request.GetResponse()
    try { $location = $response.Headers['Location'] } finally { $response.Close() }
    if ($location -notmatch '^https://github\.com/codepawl/oh-key-releases/releases/tag/(v?\d+\.\d+\.\d+)$') {
        throw "The releases page named no release ($location)."
    }
    return $Matches[1]
}

function Test-StartAtSignInEnabled {
    $null -ne (Get-ItemProperty -Path $runKey -Name 'oh-key' -ErrorAction SilentlyContinue)
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    'x86'   { 'x86' }
    default { throw "Unsupported processor architecture: $($env:PROCESSOR_ARCHITECTURE)" }
}

$workFolder = Join-Path ([IO.Path]::GetTempPath()) ('oh-key-' + [Guid]::NewGuid())
$stagedFolder = Join-Path $workFolder 'files'
New-Item -ItemType Directory -Path $stagedFolder | Out-Null
try {
    $assetName = "oh-key-windows-$architecture.exe"
    $tag = Get-LatestTag
    $downloadBase = "https://github.com/codepawl/oh-key-releases/releases/download/$tag"
    Write-Host "Downloading $assetName from $tag..."
    $assetPath = Join-Path $workFolder $assetName
    $checksumsPath = Join-Path $workFolder 'SHA256SUMS.txt'
    Invoke-WebRequest -Uri "$downloadBase/$assetName" -OutFile $assetPath -UseBasicParsing
    Invoke-WebRequest -Uri "$downloadBase/SHA256SUMS.txt" -OutFile $checksumsPath -UseBasicParsing

    $checksumLine = Get-Content $checksumsPath | Where-Object { ($_ -split '\s+')[-1].TrimStart('*') -eq $assetName } | Select-Object -First 1
    $expected = ($checksumLine -split '\s+')[0]
    $actual = (Get-FileHash $assetPath -Algorithm SHA256).Hash
    if (-not $expected -or $expected -ne $actual) {
        throw "Checksum mismatch: expected $expected, got $actual"
    }

    Stop-RunningApp
    New-Item -ItemType Directory -Path $installFolder -Force | Out-Null
    Copy-Item $assetPath (Join-Path $installFolder 'oh-key.exe') -Force
}
finally {
    Remove-Item $workFolder -Recurse -Force -ErrorAction SilentlyContinue
}

if ($StartAtSignIn -or (Test-StartAtSignInEnabled)) { Set-StartAtSignIn }
Start-Process (Join-Path $installFolder 'oh-key.exe')
Write-Host "oh-key is installed in $installFolder and running. Click the V in the tray to open its panel."
