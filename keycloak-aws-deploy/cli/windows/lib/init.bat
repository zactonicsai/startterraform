@echo off
REM Loads config.bat and state\ids.bat. Called by every numbered script.
REM No setlocal here on purpose: variables must reach the calling script.

if not exist "%HERE%config.bat" (
  echo [FAIL] config.bat not found.
  echo        Copy config.bat.example to config.bat and fill in your values.
  exit /b 1
)
call "%HERE%config.bat"

if not exist "%HERE%state" mkdir "%HERE%state"
set "STATE_FILE=%HERE%state\ids.bat"
if not exist "%STATE_FILE%" type nul > "%STATE_FILE%"
call "%STATE_FILE%"

for /f "delims=" %%R in ("%HERE%..\..") do set "REPO_ROOT=%%~fR"
set "TEMPLATE_DIR=%REPO_ROOT%\templates"
set "AWS_DEFAULT_REGION=%AWS_REGION%"

if "%PROJECT%"=="" ( echo [FAIL] PROJECT not set in config.bat & exit /b 1 )
if "%AWS_REGION%"=="" ( echo [FAIL] AWS_REGION not set in config.bat & exit /b 1 )
exit /b 0
