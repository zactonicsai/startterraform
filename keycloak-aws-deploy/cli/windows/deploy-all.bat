@echo off
REM Runs the whole build in order. Each step is re-runnable.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

echo ==============================================================
echo   Keycloak on AWS - full deployment
echo   Project : %PROJECT%
echo   Region  : %AWS_REGION%
echo   Domain  : %DOMAIN_NAME%
echo ==============================================================
echo.
echo   [warn] This creates billable AWS resources
echo   [warn] roughly $290-320/month for the full HA stack.
echo   [warn] Estimated time: 20-30 minutes, mostly waiting for RDS.
echo.
call "%HERE%lib\confirm.bat" "Continue? Type yes:" yes || exit /b 1

for %%S in (00-preflight 01-network 02-security-groups 03-secrets 04-iam 05-rds 06-alb 07-launch-template 08-asg 09-dns) do (
  echo.
  echo ############ %%S ############
  call "%HERE%%%S.bat"
  if errorlevel 1 (
    echo.
    echo [FAIL] Step %%S failed. Fix the problem and re-run: %%S.bat
    exit /b 1
  )
)

echo.
echo ############ waiting for instances to become healthy ############
call "%STATE_FILE%"
set /a WAITN=0
:waitloop
set /a WAITN+=1
for /f "usebackq delims=" %%H in (`aws elbv2 describe-target-health --target-group-arn %TG_ARN% --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text`) do set "H=%%H"
echo   healthy targets: %H%   (%WAITN% of 40 checks)
if not "%H%"=="0" goto :done
if %WAITN% GEQ 40 goto :done
timeout /t 15 /nobreak >nul
goto :waitloop

:done
  timeout /t 15 /nobreak >nul
)
:done
call "%HERE%10-verify.bat"
echo.
echo Deployment finished. State saved to: %STATE_FILE%
echo.
exit /b 0
