#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\OpenBuildsCONTROL')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$archive = Join-Path $InstallDir 'resources\app.asar'
$sidecar = "$archive.unpacked"
$version = (Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json).version

if ($version -ne '1.0.390') { throw "This branch expects CONTROL v1.0.390; source version is $version" }
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Missing archive: $archive" }
if (-not (Test-Path -LiteralPath $sidecar -PathType Container)) { throw "Missing unpacked files: $sidecar" }
if (Get-Process -Name OpenBuildsCONTROL -ErrorAction SilentlyContinue) {
    throw 'Close OpenBuilds CONTROL before patching app.asar.'
}

$nodeVersionText = (& node --version).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Node.js is required.' }
$nodeVersion = [version]($nodeVersionText.TrimStart('v'))
if ($nodeVersion -lt [version]'22.12.0') { throw "Node.js 22.12.0 or newer is required; found $nodeVersionText" }
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'npm.cmd is required.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Split-Path -Parent $InstallDir) "OpenBuildsCONTROL-MKS-DLC32-backup-$stamp"
$workDir = Join-Path $env:TEMP "OpenBuildsCONTROL-MKS-DLC32-$stamp"
if ((Test-Path -LiteralPath $backupDir) -or (Test-Path -LiteralPath $workDir)) {
    throw 'Backup or work directory already exists; retry after checking the target paths.'
}
New-Item -ItemType Directory -Path $backupDir, $workDir | Out-Null

# Backup is complete and hash-verified before any change to the installation.
$backup = Join-Path $backupDir 'app.asar'
Copy-Item -LiteralPath $archive -Destination $backup
$oldHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $oldHash) {
    throw 'Original archive backup failed checksum verification.'
}
Write-Host "Backup: $backup"
Write-Host "Original SHA256: $oldHash"

$toolDir = Join-Path $workDir 'asar-tool'
New-Item -ItemType Directory -Path $toolDir | Out-Null
& npm.cmd install --prefix $toolDir --no-save --ignore-scripts --no-audit --no-fund '@electron/asar@4.3.1'
if ($LASTEXITCODE -ne 0) { throw 'Could not install the pinned ASAR tool in the work directory.' }
$asarCli = Join-Path $toolDir 'node_modules\@electron\asar\bin\asar.mjs'

$extracted = Join-Path $workDir 'extracted'
& node $asarCli extract $archive $extracted
if ($LASTEXITCODE -ne 0) { throw 'Could not extract installed app.asar.' }
$installedVersion = (Get-Content -LiteralPath (Join-Path $extracted 'package.json') -Raw | ConvertFrom-Json).version
if ($installedVersion -ne '1.0.390') {
    throw "Installed app.asar is v$installedVersion, expected v1.0.390. Backup is at $backup"
}

$relativeFiles = @('index.js', 'app\js\websocket.js')
foreach ($relative in $relativeFiles) {
    $source = Join-Path $repoRoot $relative
    $destination = Join-Path $extracted $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw "Missing source or archive file: $relative"
    }
    Copy-Item -LiteralPath $source -Destination $destination
    & node --check $destination
    if ($LASTEXITCODE -ne 0) { throw "JavaScript syntax check failed: $relative" }
}

$packed = Join-Path $workDir 'patched\app.asar'
$unpack = '{blox-bootloader.bin,blox-grblhal-cartesian.bin,blox-grblhal-corexy.bin,blox-partition-table.bin,boot_app0.bin,bootloader_qio_80m.bin,esptool-linux,esptool-mac,esptool.exe,firmware.bin,firmware.partitions.bin,grbl.bin,grblhal-bootloader.bin,grblhal-grbl3axis-door.bin,grblhal-grbl3axis.bin,grblhal-grbl4axis.bin,grblhal-partition-table.bin}'
& node $asarCli pack $extracted $packed --unpack $unpack
if ($LASTEXITCODE -ne 0) { throw 'Could not pack patched app.asar.' }

# Verify every extracted file and every external firmware file before installation.
$roundtrip = Join-Path $workDir 'roundtrip'
& node $asarCli extract $packed $roundtrip
if ($LASTEXITCODE -ne 0) { throw 'Could not verify packed app.asar by extraction.' }
$originalFiles = @(Get-ChildItem -LiteralPath $extracted -File -Recurse)
$repackedFiles = @(Get-ChildItem -LiteralPath $roundtrip -File -Recurse)
if ($originalFiles.Count -ne $repackedFiles.Count) { throw 'Repacked archive file count differs.' }
foreach ($file in $originalFiles) {
    $relative = [IO.Path]::GetRelativePath($extracted, $file.FullName)
    $other = Join-Path $roundtrip $relative
    if (-not (Test-Path -LiteralPath $other -PathType Leaf) -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $other -Algorithm SHA256).Hash) {
        throw "Repacked archive differs at $relative"
    }
}
$packedSidecar = "$packed.unpacked"
$originalExternal = @(Get-ChildItem -LiteralPath $sidecar -File -Recurse)
$packedExternal = @(Get-ChildItem -LiteralPath $packedSidecar -File -Recurse)
if ($originalExternal.Count -ne 17 -or $packedExternal.Count -ne 17) {
    throw 'Unexpected external firmware file set.'
}
foreach ($file in $originalExternal) {
    $relative = [IO.Path]::GetRelativePath($sidecar, $file.FullName)
    $other = Join-Path $packedSidecar $relative
    if (-not (Test-Path -LiteralPath $other -PathType Leaf) -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $other -Algorithm SHA256).Hash) {
        throw "External firmware file differs at $relative"
    }
}

$incoming = "$archive.mks-incoming"
$replaceBackup = Join-Path $backupDir 'app.asar.pre-replace'
if (Get-Process -Name OpenBuildsCONTROL -ErrorAction SilentlyContinue) {
    throw 'CONTROL started during patch preparation. Backup and patched work files are retained.'
}
if (Test-Path -LiteralPath $incoming) { throw "Incoming archive already exists: $incoming" }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $oldHash) {
    throw 'Installed archive changed during patch preparation.'
}
$newHash = (Get-FileHash -LiteralPath $packed -Algorithm SHA256).Hash
Copy-Item -LiteralPath $packed -Destination $incoming
if ((Get-FileHash -LiteralPath $incoming -Algorithm SHA256).Hash -ne $newHash) {
    throw 'Incoming archive failed checksum verification.'
}
[IO.File]::Replace($incoming, $archive, $replaceBackup)
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $newHash -or
    (Get-FileHash -LiteralPath $replaceBackup -Algorithm SHA256).Hash -ne $oldHash) {
    throw 'Installed archive or automatic replacement backup failed checksum verification.'
}

Write-Host "Patched: $archive"
Write-Host "Patched SHA256: $newHash"
Write-Host "Verified archive files: $($originalFiles.Count)"
Write-Host "Verified external firmware files: $($originalExternal.Count)"
Write-Host "Restore source: $backup"
