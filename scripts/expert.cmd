@echo off
setlocal
if exist "%~dp0expert-tui.exe" (
  "%~dp0expert-tui.exe" %*
) else if exist "%~dp0..\next\target\release\expert-tui.exe" (
  "%~dp0..\next\target\release\expert-tui.exe" %*
) else if exist "%~dp0..\next\target\debug\expert-tui.exe" (
  "%~dp0..\next\target\debug\expert-tui.exe" %*
) else (
  echo expert-tui is not built. Run: cargo build --release --manifest-path "%~dp0..\next\Cargo.toml" -p expert-tui 1>&2
  exit /b 1
)
exit /b %errorlevel%
