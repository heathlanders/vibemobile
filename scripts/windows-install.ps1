# VibeMobile Windows installer (proposal 51). scripts/release.sh publishes it
# as <dl>/install.ps1 with __DL_URL__ filled in. On a new PC on the tailnet:
#   irm https://<machine>.<tailnet>.ts.net/dl/install.ps1 | iex
# Installs (or reinstalls) the latest build into %LOCALAPPDATA%\VibeMobile,
# adds a Start menu shortcut and launches it. No admin needed.
& {
  $ErrorActionPreference = 'Stop'
  $dl = '__DL_URL__'
  $dir = Join-Path $env:LOCALAPPDATA 'VibeMobile'
  $exe = Join-Path $dir 'vibemobile.exe'

  $latest = Invoke-RestMethod "$dl/latest.json"
  if (-not $latest.windows) { throw 'No Windows build has been published yet.' }

  Write-Host "Downloading VibeMobile $($latest.version)..."
  $zip = Join-Path $env:TEMP "vibemobile-windows-$($latest.version).zip"
  Invoke-WebRequest "$dl/$($latest.windows.file)" -OutFile $zip -UseBasicParsing
  if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $latest.windows.sha256) { throw 'Download is corrupt (checksum mismatch); run the installer again.' }

  # A running copy keeps its files locked.
  Get-Process vibemobile -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
  Start-Sleep -Seconds 1
  Expand-Archive $zip $dir -Force
  Remove-Item $zip

  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'VibeMobile.lnk'))
  $lnk.TargetPath = $exe
  $lnk.Save()

  Write-Host "Installed VibeMobile $($latest.version) to $dir (Start menu: VibeMobile)."
  Write-Host "To pair: daemon URL $($dl -replace '/dl$', ''), plus a pairing code from the server."
  Start-Process $exe
}
