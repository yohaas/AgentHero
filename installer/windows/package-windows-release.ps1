param(
  [string]$ManifestBaseUrl = "https://raw.githubusercontent.com/yohaas/AgentHero/main/installer/releases",
  [string]$InstallerDownloadUrl = "https://github.com/yohaas/AgentHero/raw/main/installer/AgentHeroSetup.exe",
  [string]$CommitMessage = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

function Move-ExistingTargetToArchive {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return @() }

  $targetDir = Split-Path -Parent $Path
  $archiveDir = Join-Path $targetDir "archive"
  $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $extension = [System.IO.Path]::GetExtension($Path)
  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $archivePath = Join-Path $archiveDir "$fileName-$timestamp$extension"
  $suffix = 1

  New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
  while (Test-Path -LiteralPath $archivePath) {
    $archivePath = Join-Path $archiveDir "$fileName-$timestamp-$suffix$extension"
    $suffix += 1
  }

  Move-Item -LiteralPath $Path -Destination $archivePath
  Write-Host "Archived existing $Path to $archivePath"
  return @($archivePath)
}

if ((git status --porcelain).Trim()) {
  Write-Error "Working tree must be clean before packaging."
}

git pull --ff-only

$version = (node -p "require('./package.json').version").Trim()
$releaseDir = Join-Path $repoRoot "installer\releases\v$version"
$releaseZip = Join-Path $releaseDir "agent-hero-$version-windows-x64.zip"
$archivedTargets = @()

New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null

& (Join-Path $repoRoot "scripts\windows\create-release-bundle.ps1") `
  -ManifestBaseUrl "$($ManifestBaseUrl.TrimEnd('/'))/v$version"

$artifactZip = Join-Path $repoRoot "artifacts\agent-hero-$version-windows-x64.zip"
if (-not (Test-Path -LiteralPath $artifactZip)) {
  throw "Windows release bundle was not created at $artifactZip"
}

$archivedTargets += Move-ExistingTargetToArchive $releaseZip
Copy-Item -LiteralPath $artifactZip -Destination $releaseZip -Force

$manifestPath = Join-Path $repoRoot "installer\manifest.json"
$generatedPath = Join-Path $repoRoot "artifacts\manifest.json"
$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
$generated = Get-Content -Raw -Path $generatedPath | ConvertFrom-Json
$generatedAsset = @($generated.assets | Where-Object { $_.platform -eq "windows" })[0]
if (-not $generatedAsset) { throw "Generated manifest does not contain a Windows asset." }

$asset = [ordered]@{
  type = "full"
  platform = [string]$generatedAsset.platform
  arch = [string]$generatedAsset.arch
  version = [string]$generated.version
  url = [string]$generatedAsset.url
}
if ($InstallerDownloadUrl.Trim()) {
  $asset["downloadUrl"] = $InstallerDownloadUrl.Trim()
}
$asset["sha256"] = [string]$generatedAsset.sha256
$asset["size"] = [int64]$generatedAsset.size

$keptAssets = @($manifest.assets | Where-Object {
  $type = if ($_.type) { [string]$_.type } else { "full" }
  -not ($type -eq "full" -and $_.platform -eq $asset.platform -and $_.arch -eq $asset.arch -and $_.version -eq $asset.version)
})

$manifest.version = [string]$generated.version
$manifest.releaseTag = [string]$generated.releaseTag
$manifest.commitSha = [string]$generated.commitSha
$manifest.builtAt = [string]$generated.builtAt
$manifest.assets = @($asset) + $keptAssets
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

$installerManifestPath = Join-Path $repoRoot "artifacts\windows-installer-manifest.json"
$installerManifest = $manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$installerManifest.assets[0].url = Split-Path -Leaf $releaseZip
$installerManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $installerManifestPath -Encoding UTF8

$setupPath = Join-Path $repoRoot "installer\AgentHeroSetup.exe"
$archivedTargets += Move-ExistingTargetToArchive $setupPath
& (Join-Path $repoRoot "scripts\windows\create-bootstrap-installer.ps1") `
  -ManifestUrl $installerManifestPath `
  -OutputPath $setupPath

git add `
  installer/manifest.json `
  installer/AgentHeroSetup.exe `
  "installer/releases/v$version/agent-hero-$version-windows-x64.zip"

if ($archivedTargets.Count -gt 0) {
  git add $archivedTargets
}

if (git diff --cached --quiet) {
  Write-Host "No Windows release changes to commit."
  exit 0
}

$message = if ($CommitMessage.Trim()) { $CommitMessage.Trim() } else { "Add Windows full release $version" }
git commit -m $message
