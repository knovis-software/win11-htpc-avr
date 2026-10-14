# HtpcConfig.ps1 - reads htpc.config.json from this folder (the install folder). Dot-source it, then:
#   $cfg = Get-HtpcConfig
# Copy htpc.config.example.json to htpc.config.json and fill it in; the real file is never committed.
function Get-HtpcConfig {
  $p = Join-Path $PSScriptRoot 'htpc.config.json'
  if (-not (Test-Path $p)) { throw "missing $p - copy htpc.config.example.json to htpc.config.json and fill it in" }
  Get-Content $p -Raw | ConvertFrom-Json
}
