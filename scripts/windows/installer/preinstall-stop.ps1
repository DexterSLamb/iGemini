# preinstall-stop.ps1 -- terminate iGemini processes that LOCK files under the install dir,
# then WAIT until the key native addon (bcrypt.node) is actually unlocked, so Inno can overwrite it
# (fixes the "bcrypt.node cannot be replaced / file in use" error).
# Run by iGemini.iss PrepareToInstall (before any file is copied), via ExtractTemporaryFile.
# Pure ASCII on purpose (no BOM needed). Scoped kills -- does NOT touch unrelated node/powershell.
# Logs every run to %TEMP%\igemini-preinstall.log so a failed/again-locked run is NEVER silent.
$ErrorActionPreference = 'SilentlyContinue'
$app = Join-Path $env:LOCALAPPDATA 'iGemini'
$log = Join-Path $env:TEMP 'igemini-preinstall.log'
function L($m) { try { ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Add-Content -Path $log } catch {} }

# bcrypt.node is the file Inno fails to overwrite -- use it as the "are locks released yet?" probe.
$bcrypt = Join-Path $app 'claudecodeui\node_modules\bcrypt\prebuilds\win32-x64\bcrypt.node'
function Locked($p) {
  if (-not (Test-Path $p)) { return $false }          # fresh install: file not there yet = not locked
  try { $fs = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false }
  catch { return $true }
}

function KillRound {
  # 1) web server node (holds bcrypt.node etc.) -- by listening port 8888
  Get-NetTCPConnection -LocalPort 8888 -State Listen |
    ForEach-Object { L "kill :8888 owner PID=$($_.OwningProcess)"; Stop-Process -Id $_.OwningProcess -Force }
  # 2) WebView2 shell + its child msedgewebview2 processes (tree kill by unique image name)
  & taskkill /F /IM iGemini.exe /T 2>$null | Out-Null
  # 3) node.exe / claude.exe (claude code) from the install dir. Match by ExecutablePath OR CommandLine
  #    (ExecutablePath can be empty when WMI can't read it -- then fall back to the path in the cmdline).
  Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -eq 'node.exe' -or $_.Name -eq 'claude.exe') -and
      ( ($_.ExecutablePath -and ($_.ExecutablePath -like "$app*")) -or ($_.CommandLine -like "*$app*") )
    } |
    ForEach-Object { L "kill $($_.Name) PID=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force }
  # 4) the launcher / wrapper shells: run-server.ps1 powershell, and the cmd shims npm spawns
  #    ('cmd /c npm.cmd run server' and 'cmd /c node dist-server/server/index.js').
  Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'cmd.exe') -and
      ( $_.CommandLine -like '*run-server*' -or
        $_.CommandLine -like '*dist-server*server*index*' -or
        $_.CommandLine -like '*npm.cmd*run*server*' )
    } |
    ForEach-Object { L "kill $($_.Name) PID=$($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force }
}

L "=== preinstall-stop start (app=$app, bcrypt locked=$(Locked $bcrypt)) ==="
$freed = $false
for ($i = 1; $i -le 10; $i++) {
  KillRound
  Start-Sleep -Milliseconds 500
  if (-not (Locked $bcrypt)) { L "bcrypt FREE after round $i"; $freed = $true; break }
  L "bcrypt still LOCKED after round $i -- retrying"
}
if (-not $freed) { L "WARNING: bcrypt STILL LOCKED after 10 rounds -- install may hit file-in-use" }
L "=== preinstall-stop end (freed=$freed) ==="
