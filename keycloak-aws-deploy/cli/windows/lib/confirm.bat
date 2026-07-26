@echo off
REM confirm.bat "prompt text" EXPECTED
set "_ANS="
set /p "_ANS=%~1 "
if /i not "%_ANS%"=="%~2" (
  echo   [FAIL] Aborted by user.
  exit /b 1
)
exit /b 0
