param(
  [string]$Manifest = ".\pack.manifest.json",
  [switch]$Overwrite,
  [switch]$Preflight,   # только проверки (версии, размеры, состав)
  [switch]$DryRun       # показать, что пойдёт в архив, без упаковки
)

$ErrorActionPreference = "Stop"
function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Warn($m){ Write-Host "⚠ $m" -ForegroundColor Yellow }
function Ok($m){ Write-Host "✓ $m" -ForegroundColor Green }

# --- Проверки окружения ---
$min = [Version]"5.1"
if ($PSVersionTable.PSVersion -lt $min) { throw "Нужен PowerShell >= 5.1" }
if (-not (Get-Command Compress-Archive -ErrorAction SilentlyContinue)) {
  throw "Нет Compress-Archive. Запусти в PowerShell 5.1+/7+."
}
if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest" }

$cfg  = Get-Content $Manifest -Raw | ConvertFrom-Json
$dist = if ($cfg.dist) { $cfg.dist } else { ".\dist" }
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

$gExDirs  = @(); if ($cfg.global_exclude_dirs)  { $gExDirs  = @($cfg.global_exclude_dirs) }
$gExFiles = @(); if ($cfg.global_exclude_files) { $gExFiles = @($cfg.global_exclude_files) }

function Get-Files {
  param([string]$Source,[string[]]$ExDirs,[string[]]$ExFiles)
  $root = (Resolve-Path $Source).Path
  if (-not (Test-Path $root)) { throw "Source not found: $root" }
  $all = Get-ChildItem -LiteralPath $root -Recurse -File -Force
  $all | Where-Object {
    $rel = $_.FullName.Substring($root.Length).TrimStart('\','/')
    $rel = $rel -replace '\\','/'
    foreach($d in $ExDirs){ if($rel -match "(?i)(^|/)$([regex]::Escape($d))(/|$)") { return $false } }
    foreach($p in $ExFiles){ if($_.Name -like $p -or $rel -like $p){ return $false } }
    $true
  }
}

function Show-Summary {
  param([string]$Name,[string]$Source,[Object[]]$Files,[int]$MaxMB)
  $sum = ($Files | Measure-Object Length -Sum)
  $mb  = [Math]::Round($sum.Sum/1MB,2)
  Info "— $Name @ $Source → $($Files.Count) файлов, ~${mb}MB"
  $top = $Files | Sort-Object Length -Descending | Select-Object -First 5
  foreach($f in $top){ $sz=[Math]::Round($f.Length/1MB,2); Write-Host "   · $($f.FullName) ($sz MB)" }
  if($MaxMB -gt 0){
    $overs = $Files | Where-Object { $_.Length -gt ($MaxMB*1MB) }
    foreach($o in $overs){ $sz=[Math]::Round($o.Length/1MB,2); Warn "Превышает лимит ${MaxMB}MB → $($o.FullName) ($sz MB)" }
  }
}

$checksums = Join-Path $dist "SHA256SUMS.txt"
if (-not $Preflight -and -not $DryRun) { if(Test-Path $checksums){ Remove-Item $checksums -Force } }

foreach($p in $cfg.packages){
  if(-not $p.name -or -not $p.source -or -not $p.output){
    throw "В манифесте у пакета не задано name/source/output."
  }
  $exD = @($gExDirs + @($p.exclude_dirs))
  $exF = @($gExFiles + @($p.exclude_files))

  $files = Get-Files -Source $p.source -ExDirs $exD -ExFiles $exF
  if($files.Count -eq 0){ Warn "Пакет '$($p.name)': файлов нет — пропуск."; continue }

  $max = if($p.max_file_mb){ [int]$p.max_file_mb } else { 0 }
  Show-Summary -Name $p.name -Source $p.source -Files $files -MaxMB $max

  $zip = Join-Path $dist ("{0}.zip" -f $p.output)

  if($Preflight -or $DryRun){ continue }
  if(Test-Path $zip){
    if($Overwrite){ Remove-Item $zip -Force } else { Write-Host "Skip (exists): $(Split-Path $zip -Leaf)"; continue }
  }

  Info "→ Упаковка: $(Split-Path $zip -Leaf)"
  Compress-Archive -Path ($files | ForEach-Object FullName) -DestinationPath $zip -CompressionLevel Optimal
  $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
  "$hash  $(Split-Path $zip -Leaf)" | Out-File -FilePath $checksums -Append -Encoding ascii
  Ok "Готово: $(Split-Path $zip -Leaf) | SHA256=$hash"
}

if($Preflight){ Ok "`nПрефлайт завершён." }
elseif($DryRun){ Ok "`nDryRun завершён." }
else{ Ok "`nAll done. Output: $dist" }
