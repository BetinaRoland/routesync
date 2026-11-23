# Copies this RouteSync package into an existing project folder, keeping your Firebase setup.
# Kept as they are in the target: lib\firebase_options.dart, android\, ios\, web\, windows\, functions\.env, node_modules.
# A timestamped backup of the target is made first.
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\tools\sync_into_project.ps1 -Target C:\Projects\RouteSync
param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $Target)) { throw "Target folder not found: $Target" }
if ((Resolve-Path $src).Path -eq (Resolve-Path $Target).Path) { throw 'Source and target are the same folder.' }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = "${Target}_backup_$stamp"
robocopy $Target $backup /E /XD build .dart_tool node_modules .git /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Backup failed. Nothing was changed.' }
Write-Host "Backup created: $backup"

function Sync-Folder($from, $to, $excludeFiles = @(), $excludeDirs = @()) {
  $a = @($from, $to, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($excludeFiles.Count -gt 0) { $a += '/XF'; $a += $excludeFiles }
  if ($excludeDirs.Count -gt 0) { $a += '/XD'; $a += $excludeDirs }
  robocopy @a | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copy failed: $from" }
}

Sync-Folder "$src\lib" "$Target\lib" @('firebase_options.dart')
Sync-Folder "$src\test" "$Target\test"
Sync-Folder "$src\assets" "$Target\assets"
Sync-Folder "$src\tools" "$Target\tools" @() @('node_modules')
Sync-Folder "$src\android_notes" "$Target\android_notes"
Sync-Folder "$src\docs" "$Target\docs"
Sync-Folder "$src\.github" "$Target\.github"
foreach ($f in 'firestore.rules', 'database.rules.json', 'firestore.indexes.json', 'firebase.json', 'analysis_options.yaml', 'README.md', 'CHANGES.md', 'RUN_GUIDE.md', 'pubspec.yaml') {
  Copy-Item "$src\$f" "$Target\$f" -Force
}

if (-not (Test-Path "$Target\lib\firebase_options.dart")) {
  Write-Warning 'lib\firebase_options.dart is missing. Run: dart pub global run flutterfire_cli:flutterfire configure --project=routesync-94a88 --platforms=web,android'
}
if (Test-Path "$Target\functions") { Write-Warning 'The old functions folder is no longer used (the free edition has no Cloud Functions). You can delete it, and the allocator folder too.' }
Write-Host 'Done. Next, inside the target folder: flutter pub get, flutter test, flutter analyze, flutter run -d chrome'
