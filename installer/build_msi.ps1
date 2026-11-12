<#
.SYNOPSIS
  构建 ProcFlow 的 Windows MSI 安装包（WiX Toolset 5）。

.DESCRIPTION
  首次使用需安装 WiX 5 与 UI 扩展：
    dotnet tool install --tool-path <目录> wix --version 5.*
    <目录>\wix.exe extension add WixToolset.UI.wixext/5.0.2

  然后执行：
    powershell -ExecutionPolicy Bypass -File installer\build_msi.ps1 -WixPath <目录>\wix.exe

  产物：build\installer\ProcFlow-<版本>-x64.msi
#>
param(
  [string]$WixPath = '',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ReleaseDir = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'

if (-not $SkipBuild) {
  Push-Location $ProjectRoot
  try {
    Write-Host '==> flutter build windows --release'
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
      throw 'flutter build windows --release 失败'
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir 'procflow.exe'))) {
  throw "未找到 Release 产物：$ReleaseDir\procflow.exe"
}

if (-not $WixPath) {
  $command = Get-Command wix -ErrorAction SilentlyContinue
  if ($command) { $WixPath = $command.Source }
}
if (-not $WixPath -or -not (Test-Path -LiteralPath $WixPath)) {
  throw '未找到 wix.exe，请安装 WiX 5 并通过 -WixPath 指定路径。'
}

$wixVersion = (& $WixPath --version | Select-Object -First 1).ToString().Trim()
if ($wixVersion -notmatch '^5\.') {
  throw "需要 WiX 5.x（当前 $wixVersion）。WiX 7 需要接受 OSMF 协议，请改用 WiX 5。"
}
$wixShortVersion = $wixVersion.Split('+')[0]

$versionMatch = [regex]::Match(
  (Get-Content -LiteralPath (Join-Path $ProjectRoot 'pubspec.yaml') -Raw),
  '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)'
)
if (-not $versionMatch.Success) {
  throw '无法从 pubspec.yaml 解析版本号'
}
$version = $versionMatch.Groups[1].Value

# ---------------------------------------------------------------
# 生成文件清单：把 Release 目录下所有文件写成 WiX Component
# ---------------------------------------------------------------
function ConvertTo-XmlText([string]$value) {
  return [System.Security.SecurityElement]::Escape($value)
}

# 文件路径 => 稳定 GUID，保证升级安装时组件身份不变
function Get-StableGuid([string]$key) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $hash = $md5.ComputeHash(
      [System.Text.Encoding]::UTF8.GetBytes("ProcFlow|$key")
    )
    return (New-Object System.Guid (,$hash)).ToString('B').ToUpperInvariant()
  } finally {
    $md5.Dispose()
  }
}

$files = @(
  Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File | Sort-Object FullName
)
$filesByDir = @{}
$dirNames = New-Object 'System.Collections.Generic.HashSet[string]'
$entries = @()

$index = 0
foreach ($file in $files) {
  $relative = $file.FullName.Substring($ReleaseDir.Length + 1)
  $dir = Split-Path $relative -Parent
  if (-not $dir) { $dir = '' }

  if (-not $filesByDir.ContainsKey($dir)) {
    $filesByDir[$dir] = New-Object 'System.Collections.Generic.List[object]'
  }

  $entry = [pscustomobject]@{
    Relative    = $relative
    Directory   = $dir
    FileId      = "F$index"
    ComponentId = "C$index"
    Guid        = Get-StableGuid $relative
  }
  $filesByDir[$dir].Add($entry)
  $entries += $entry

  $parent = $dir
  while ($parent) {
    [void]$dirNames.Add($parent)
    $parent = Split-Path $parent -Parent
  }
  $index++
}

$dirIds = @{}
$index = 0
foreach ($dir in ($dirNames | Sort-Object)) {
  $dirIds[$dir] = "Dir$index"
  $index++
}

$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('<?xml version="1.0" encoding="utf-8"?>')
$lines.Add('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
$lines.Add('  <Fragment>')
$lines.Add('    <DirectoryRef Id="INSTALLFOLDER">')

function Write-Files {
  param([string]$Path, [int]$Depth)
  if (-not $filesByDir.ContainsKey($Path)) { return }

  $pad = ' ' * $Depth
  foreach ($entry in @($filesByDir[$Path] | Sort-Object Relative)) {
    $source = '$(var.SourceDir)\' + (ConvertTo-XmlText $entry.Relative)
    $lines.Add("$pad<Component Id=""$($entry.ComponentId)"" Guid=""$($entry.Guid)"">")
    $lines.Add("$pad  <File Id=""$($entry.FileId)"" Source=""$source"" KeyPath=""yes"" />")
    $lines.Add("$pad</Component>")
  }
}

function Write-Directories {
  param([string]$Parent, [int]$Depth)
  $children = @(
    $dirNames |
      Where-Object { $_ -ne '' -and (Split-Path $_ -Parent) -eq $Parent } |
      Sort-Object
  )
  foreach ($child in $children) {
    $pad = ' ' * $Depth
    $name = ConvertTo-XmlText (Split-Path $child -Leaf)
    $lines.Add("$pad<Directory Id=""$($dirIds[$child])"" Name=""$name"">")
    Write-Files -Path $child -Depth ($Depth + 2)
    Write-Directories -Parent $child -Depth ($Depth + 2)
    $lines.Add("$pad</Directory>")
  }
}

Write-Files -Path '' -Depth 6
Write-Directories -Parent '' -Depth 6
$lines.Add('    </DirectoryRef>')
$lines.Add('  </Fragment>')
$lines.Add('  <Fragment>')
$lines.Add('    <ComponentGroup Id="AppFiles">')
foreach ($entry in ($entries | Sort-Object Relative)) {
  $lines.Add("      <ComponentRef Id=""$($entry.ComponentId)"" />")
}
$lines.Add('    </ComponentGroup>')
$lines.Add('  </Fragment>')
$lines.Add('</Wix>')

$workDir = Join-Path $ProjectRoot 'build\wix'
$outputDir = Join-Path $ProjectRoot 'build\installer'
New-Item -ItemType Directory -Force -Path $workDir, $outputDir | Out-Null

$appFilesWxs = Join-Path $workDir 'AppFiles.wxs'
Set-Content -LiteralPath $appFilesWxs -Value $lines -Encoding UTF8

# ---------------------------------------------------------------
# 确保 WiX UI 扩展已安装（只安装与当前 WiX 同版本的扩展）
# ---------------------------------------------------------------
$extensionList = & $WixPath extension list 2>$null
if ($extensionList -notmatch 'WixToolset\.UI\.wixext\s+5\.') {
  Write-Host "==> 安装 WixToolset.UI.wixext $wixShortVersion"
  & $WixPath extension add "WixToolset.UI.wixext/$wixShortVersion"
  if ($LASTEXITCODE -ne 0) {
    throw '安装 WiX UI 扩展失败，请检查网络或手动执行 wix extension add'
  }
}

# ---------------------------------------------------------------
# 编译 MSI
# ---------------------------------------------------------------
# 同一版本固定 ProductCode（重建仍视为同一产品），不同版本自动变化
$productCode = Get-StableGuid "ProductCode|$version"
$msiPath = Join-Path $outputDir "ProcFlow-$version-x64.msi"
Write-Host "==> wix build $(Split-Path $msiPath -Leaf)"

& $WixPath build `
  (Join-Path $ProjectRoot 'installer\Product.wxs') `
  $appFilesWxs `
  -arch x64 `
  -ext WixToolset.UI.wixext `
  -d "SourceDir=$ReleaseDir" `
  -d "ProjectRoot=$ProjectRoot" `
  -d "Version=$version" `
  -d "ProductCode=$productCode" `
  -o $msiPath

if ($LASTEXITCODE -ne 0) {
  throw 'MSI 构建失败'
}
if (-not (Test-Path -LiteralPath $msiPath)) {
  throw "MSI 未生成：$msiPath"
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $msiPath).Length / 1MB, 1)
Write-Host "完成：$msiPath ($sizeMb MB)"
