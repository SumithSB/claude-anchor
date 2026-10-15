# Claude Anchor uninstaller for Windows (PowerShell 5.1+).
#   irm https://raw.githubusercontent.com/SumithSB/claude-anchor/main/uninstall.ps1 | iex
function Uninstall-ClaudeAnchor {
  $ErrorActionPreference = 'Stop'
  function Step($m) { Write-Host "==> $m" }
  $ahome = if ($env:CLAUDE_ANCHOR_HOME) { $env:CLAUDE_ANCHOR_HOME } else { Join-Path $HOME '.claude-anchor' }

  Step 'Quitting Claude Anchor'
  Get-Process claude-anchor -ErrorAction SilentlyContinue | Stop-Process -Force

  $anchor = Join-Path $ahome 'bin\anchor.exe'
  if (Test-Path $anchor) {
    Step 'Removing the PowerShell profile line and editor integration'
    & $anchor uninstall
  }

  Step 'Removing the app'
  $key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -eq 'Claude Anchor' } | Select-Object -First 1
  $cmd = if ($key) { (Get-ItemProperty $key.PSPath).UninstallString } else { $null }
  if ($cmd) {
    $exe = $cmd.Trim('"')
    if (Test-Path $exe) { Start-Process -FilePath $exe -ArgumentList '/S' -Wait }
    else { Write-Warning "Uninstaller not found at $exe" }
  } else {
    Write-Host 'No installed app found.'
  }
  # Login-item entry, in case the uninstaller left it
  Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Claude Anchor' -ErrorAction SilentlyContinue

  if (Test-Path $ahome) { Step "Kept $ahome (settings, routes, usage history, accounts); delete it to remove them" }
  Write-Host 'Done. ~\.claude was not touched.'
}

try { Uninstall-ClaudeAnchor } catch { Write-Error "error: $($_.Exception.Message)" }
