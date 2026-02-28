$lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
if (-not (Test-Path $lua)) {
  Write-Error "Lua runtime not found at '$lua'. Install 'Lua for Windows' first."
  exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$luaScript = Join-Path $scriptDir "run_transposer_demo.lua"

& $lua $luaScript
exit $LASTEXITCODE
