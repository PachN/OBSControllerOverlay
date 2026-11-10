# Erzeugt Controller-Overlay-Anleitung.pdf aus guide\template.html
# Voraussetzungen: Node.js und Microsoft Edge
$ErrorActionPreference = 'Stop'
$root  = Split-Path $PSScriptRoot
$guide = $PSScriptRoot
$html  = Join-Path $env:TEMP 'Controller-Overlay-Anleitung.html'
$pdf   = Join-Path $root 'Controller-Overlay-Anleitung.pdf'
$prof  = Join-Path $env:TEMP 'controller-overlay-edge-profile'

node (Join-Path $guide 'build.js') (Join-Path $root 'controller-overlay.lua') (Join-Path $guide 'template.html') $html

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
$url = 'file:///' + ($html -replace '\\', '/')
Start-Process $edge -Wait -ArgumentList '--headless', '--disable-gpu', '--no-pdf-header-footer',
  "--user-data-dir=`"$prof`"", "--print-to-pdf=`"$pdf`"", "`"$url`""
Write-Host "PDF geschrieben: $pdf"
