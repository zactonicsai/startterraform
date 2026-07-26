@echo off
REM save.bat NAME VALUE
REM Sets the variable in the CALLER's environment (no setlocal) and persists
REM it to state\ids.bat, replacing any previous line for the same name.

if "%~1"=="" exit /b 1
set "%~1=%~2"

if exist "%STATE_FILE%" (
  findstr /v /b /c:"set %~1=" "%STATE_FILE%" > "%STATE_FILE%.tmp" 2>nul
  move /y "%STATE_FILE%.tmp" "%STATE_FILE%" >nul 2>nul
)
>>"%STATE_FILE%" echo set %~1=%~2
echo   [ok] %~1 = %~2
exit /b 0
