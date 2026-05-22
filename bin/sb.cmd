@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
if defined CLAUDE_PLUGIN_ROOT (
  set "PLUGIN_ROOT=%CLAUDE_PLUGIN_ROOT%"
) else (
  for %%I in ("%SCRIPT_DIR%..") do set "PLUGIN_ROOT=%%~fI"
)
set "BUNDLE=%PLUGIN_ROOT%\mcp\dist\cli\sb-entry.bundle.js"
if not exist "%BUNDLE%" (
  echo sb: bundle not found at %BUNDLE% 1>&2
  echo sb: run 'npm --prefix %PLUGIN_ROOT%\mcp run build' first 1>&2
  exit /b 1
)
node "%BUNDLE%" %*
