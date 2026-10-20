# Claude Anchor installer for Windows (PowerShell 5.1+).
#   irm https://raw.githubusercontent.com/SumithSB/claude-anchor/main/install.ps1 | iex
# Env: CLAUDE_ANCHOR_NO_SHELL=1 (skip the profile line and cmd.exe AutoRun), CLAUDE_ANCHOR_NO_LAUNCH=1
# The installer is unsigned, so SmartScreen may warn when the app first runs.

function Install-ClaudeAnchor {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $repo = 'SumithSB/claude-anchor'
  function Step($m) { Write-Host "==> $m" }

  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw "Only 64-bit Windows (x64) has a prebuilt release; found $env:PROCESSOR_ARCHITECTURE." }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("claude-anchor-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    Step 'Looking for the latest release'
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"

    # Download an asset matching $pattern plus its .sha256 and verify it. Returns the local path.
    function Get-Asset($pattern) {
      $a = $rel.assets | Where-Object { $_.name -match $pattern -and $_.name -notmatch '\.sha256$' } | Select-Object -First 1
      $s = $rel.assets | Where-Object { $_.name -match ($pattern.TrimEnd('$') + '\.sha256$') } | Select-Object -First 1
      if (-not $a -or -not $s) { throw "The latest release has no asset matching $pattern (or its .sha256)." }
      Step "Downloading $($a.name)"
      $f = Join-Path $tmp $a.name
      Invoke-WebRequest -UseBasicParsing -Uri $a.browser_download_url -OutFile $f
      $sf = Join-Path $tmp $s.name
      Invoke-WebRequest -UseBasicParsing -Uri $s.browser_download_url -OutFile $sf
      $want = ((Get-Content -Raw $sf).Trim() -split '\s+')[0]
      $got = (Get-FileHash -Algorithm SHA256 $f).Hash
      if ($want -ne $got) { throw "Checksum mismatch for $($a.name). Retry later." }
      $f
    }

    $setup = Get-Asset '-setup\.exe$'
    $zip = Get-Asset 'windows-x86_64\.zip$'

    Step 'Installing the app (per-user, silent)'
    Get-Process claude-anchor -ErrorAction SilentlyContinue | Stop-Process -Force
    $p = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "The installer exited with code $($p.ExitCode)." }

    Step 'Installing the anchor CLI'
    $dir = Join-Path $tmp 'cli'
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $anchor = Join-Path $dir 'anchor.exe'
    $ahome = if ($env:CLAUDE_ANCHOR_HOME) { $env:CLAUDE_ANCHOR_HOME } else { Join-Path $HOME '.claude-anchor' }
    if ($env:CLAUDE_ANCHOR_NO_SHELL -eq '1') {
      Step 'Skipping the PowerShell and cmd.exe hooks (CLAUDE_ANCHOR_NO_SHELL=1)'
      New-Item -ItemType Directory -Force (Join-Path $ahome 'bin') | Out-Null
      Copy-Item $anchor (Join-Path $ahome 'bin\anchor.exe') -Force
      Copy-Item $anchor (Join-Path $ahome 'bin\claude-wrapper.exe') -Force
    } else {
      # Capture both streams so a failure says why (PowerShell 5.1 can hide native stderr under iex).
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $out = & $anchor install 2>&1 | ForEach-Object { "$_" }
      $code = $LASTEXITCODE; $ErrorActionPreference = $prev
      $out | ForEach-Object { Write-Host "  $_" }
      if ($code -eq -1073741515) { throw 'anchor.exe could not start: a system DLL is missing (0xC0000135). Install the Microsoft Visual C++ Redistributable (x64) from https://aka.ms/vs/17/release/vc_redist.x64.exe, then run this again.' }
      if ($code -ne 0) { throw "anchor install failed (exit $code): $($out -join ' ')" }
    }

    $exe = Join-Path $env:LOCALAPPDATA 'Claude Anchor\claude-anchor.exe'
    if ($env:CLAUDE_ANCHOR_NO_LAUNCH -eq '1') { Step 'Skipping launch (CLAUDE_ANCHOR_NO_LAUNCH=1)' }
    elseif (Test-Path $exe) { Step 'Launching Claude Anchor'; Start-Process $exe }

    Write-Host ''
    Write-Host 'Installed:'
    Write-Host "  App: $exe"
    Write-Host "  CLI: $(Join-Path $ahome 'bin\anchor.exe')"
    if ($env:CLAUDE_ANCHOR_NO_SHELL -ne '1') { Write-Host '  Shell hooks: one marked line in each PowerShell profile (# claude-anchor), and a cmd.exe AutoRun macro' }
    Write-Host 'Next: click the anchor in the system tray, then Accounts -> Add account. Open a new terminal for `claude` to be routed.'
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
      Write-Warning 'Claude Code CLI not found. Install it with: irm https://claude.ai/install.ps1 | iex'
    }
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

try { Install-ClaudeAnchor } catch { Write-Error "error: $($_.Exception.Message)" }
