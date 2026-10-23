# Downloads a CI build of the demo for Windows (x64), installs it and starts it.
#
#   irm https://raw.githubusercontent.com/vymalo/frb-tray-spike/main/scripts/run-windows.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File scripts\run-windows.ps1 [-Build N] [-Dir DIR] [-Logs]
#   powershell -ExecutionPolicy Bypass -File scripts\run-windows.ps1 -Uninstall [-Dir DIR]
#
#   -Build N     build N from the releases page (default: the latest build)
#   -Dir DIR     where to put the app (default: %LOCALAPPDATA%\frb-tray-spike)
#   -Logs        run in this console and show the app's output; Ctrl-C quits
#   -Uninstall   quit the app and remove it
param(
  [int]$Build = 0,
  [string]$Dir = (Join-Path $env:LOCALAPPDATA 'frb-tray-spike'),
  [switch]$Logs,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest downloads far faster without its progress bar.
$ProgressPreference = 'SilentlyContinue'

$app = Join-Path $Dir 'agent_tray_demo'
if ($Uninstall) {
  Get-Process agent_tray_demo -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  if (Test-Path $app) { Remove-Item -Recurse -Force $app }
  # Only removes the folder if nothing else was put in it.
  if ((Test-Path $Dir) -and -not (Get-ChildItem $Dir)) { Remove-Item $Dir }
  Write-Host "Removed $app"
  return
}

$repo = 'vymalo/frb-tray-spike'
$asset = 'agent_tray_demo-windows-x64.zip'
if ($Build -gt 0) {
  $url = "https://github.com/$repo/releases/download/build-$Build/$asset"
} else {
  $url = "https://github.com/$repo/releases/latest/download/$asset"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zip = Join-Path $tmp $asset
  Write-Host "Downloading $url"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

  # A copy that's still running would keep its tray icon, old code and a lock
  # on its files.
  Get-Process agent_tray_demo -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 500

  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  if (Test-Path $app) { Remove-Item -Recurse -Force $app }
  Expand-Archive -Path $zip -DestinationPath $Dir -Force
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# Downloaded files carry a "from the internet" mark that makes Windows warn
# about each of them; the app isn't signed.
Get-ChildItem -Recurse $app | Unblock-File
$exe = Join-Path $app 'agent_tray_demo.exe'
Write-Host "Installed $exe"

if ($Logs) {
  Write-Host 'Running with logs. Look for the icon in the taskbar tray; Ctrl-C quits.'
  # A GUI app doesn't hold the console by itself; wait for it so its output
  # (it attaches to this console) shows up here.
  Start-Process $exe -NoNewWindow -Wait
} else {
  Start-Process $exe
  Write-Host 'Running. Look for the icon in the taskbar tray (it may be behind the ^ arrow) and click it.'
  Write-Host "Quit from the popover's Quit button."
}
