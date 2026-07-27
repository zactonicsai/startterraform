@echo off
REM ===========================================================================
REM run.bat - Windows twin of run.sh. Same commands, same behaviour.
REM
REM   scripts\run.bat <command> [stack] [extra terraform flags...]
REM
REM STACKS
REM   db ^| database ^| network ^| 1   -^> 01-network-database
REM   keycloak ^| compute ^| app ^| 2  -^> 02-keycloak-compute
REM   alb ^| lb ^| public ^| 3         -^> 03-public-access
REM   all                           -^> every stack, in the safe order
REM
REM COMMANDS
REM   init  validate  fmt  plan  apply  reconfigure  redeploy
REM   destroy  output  status  clean  help
REM
REM EXAMPLES
REM   scripts\run.bat apply all
REM   scripts\run.bat plan keycloak
REM   scripts\run.bat destroy alb
REM   scripts\run.bat reconfigure keycloak
REM   set AUTO_APPROVE=1 ^&^& scripts\run.bat apply all
REM ===========================================================================

setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fI"

set "STACK_1=01-network-database"
set "STACK_2=02-keycloak-compute"
set "STACK_3=03-public-access"

REM --- find terraform or opentofu -------------------------------------------
if not defined TF_BIN (
  where terraform >nul 2>&1 && set "TF_BIN=terraform"
)
if not defined TF_BIN (
  where tofu >nul 2>&1 && set "TF_BIN=tofu"
)
if not defined TF_BIN (
  echo ERROR: neither 'terraform' nor 'tofu' was found on your PATH.
  exit /b 1
)

if not defined AUTO_APPROVE set "AUTO_APPROVE=0"
set "APPROVE="
if "%AUTO_APPROVE%"=="1" set "APPROVE=-auto-approve"

REM --- read the arguments ----------------------------------------------------
set "COMMAND=%~1"
if "%COMMAND%"=="" set "COMMAND=help"
shift

set "STACK_ARG=%~1"
if "%STACK_ARG%"=="" set "STACK_ARG=all"

set "EXTRA="
set "SKIP_SHIFT=0"
echo %STACK_ARG% | findstr /b /c:"-" >nul && set "SKIP_SHIFT=1"
if "%SKIP_SHIFT%"=="1" ( set "STACK_ARG=all" ) else ( shift )

:collect
if "%~1"=="" goto collected
set "EXTRA=!EXTRA! %~1"
shift
goto collect
:collected

REM --- turn the friendly stack name into a folder name -----------------------
set "STACK="
if /i "%STACK_ARG%"=="1"        set "STACK=%STACK_1%"
if /i "%STACK_ARG%"=="db"       set "STACK=%STACK_1%"
if /i "%STACK_ARG%"=="database" set "STACK=%STACK_1%"
if /i "%STACK_ARG%"=="network"  set "STACK=%STACK_1%"
if /i "%STACK_ARG%"=="net"      set "STACK=%STACK_1%"
if /i "%STACK_ARG%"=="2"        set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="kc"       set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="keycloak" set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="compute"  set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="app"      set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="asg"      set "STACK=%STACK_2%"
if /i "%STACK_ARG%"=="3"        set "STACK=%STACK_3%"
if /i "%STACK_ARG%"=="alb"      set "STACK=%STACK_3%"
if /i "%STACK_ARG%"=="lb"       set "STACK=%STACK_3%"
if /i "%STACK_ARG%"=="public"   set "STACK=%STACK_3%"
if /i "%STACK_ARG%"=="access"   set "STACK=%STACK_3%"
if /i "%STACK_ARG%"=="all"      set "STACK=all"

if "%STACK%"=="" (
  echo ERROR: unknown stack "%STACK_ARG%". Use: db ^| keycloak ^| alb ^| all
  exit /b 2
)

REM --- dispatch --------------------------------------------------------------
if /i "%COMMAND%"=="help"        goto :usage
if /i "%COMMAND%"=="-h"          goto :usage
if /i "%COMMAND%"=="--help"      goto :usage
if /i "%COMMAND%"=="init"        goto :cmd_init
if /i "%COMMAND%"=="validate"    goto :cmd_validate
if /i "%COMMAND%"=="fmt"         goto :cmd_fmt
if /i "%COMMAND%"=="plan"        goto :cmd_plan
if /i "%COMMAND%"=="apply"       goto :cmd_apply
if /i "%COMMAND%"=="reconfigure" goto :cmd_reconfigure
if /i "%COMMAND%"=="redeploy"    goto :cmd_redeploy
if /i "%COMMAND%"=="destroy"     goto :cmd_destroy
if /i "%COMMAND%"=="output"      goto :cmd_output
if /i "%COMMAND%"=="status"      goto :cmd_status
if /i "%COMMAND%"=="clean"       goto :cmd_clean

echo ERROR: unknown command "%COMMAND%".
goto :usage

REM ===========================  commands  ====================================

:cmd_init
if "%STACK%"=="all" (
  call :run_init %STACK_1% || exit /b 1
  call :run_init %STACK_2% || exit /b 1
  call :run_init %STACK_3% || exit /b 1
) else ( call :run_init %STACK% || exit /b 1 )
goto :eof

:cmd_validate
if "%STACK%"=="all" (
  call :run_validate %STACK_1% || exit /b 1
  call :run_validate %STACK_2% || exit /b 1
  call :run_validate %STACK_3% || exit /b 1
) else ( call :run_validate %STACK% || exit /b 1 )
goto :eof

:cmd_plan
if "%STACK%"=="all" (
  call :run_plan %STACK_1% || exit /b 1
  call :run_plan %STACK_2% || exit /b 1
  call :run_plan %STACK_3% || exit /b 1
) else ( call :run_plan %STACK% || exit /b 1 )
goto :eof

:cmd_apply
REM Order matters: database, then Keycloak, then the load balancer.
if "%STACK%"=="all" (
  call :run_apply %STACK_1% || exit /b 1
  call :run_apply %STACK_2% || exit /b 1
  call :run_apply %STACK_3% || exit /b 1
  echo.
  echo Everything is up. Your admin console URL:
  pushd "%ROOT_DIR%" && %TF_BIN% -chdir=%STACK_3% output -raw keycloak_admin_console_url & popd
  echo.
) else ( call :run_apply %STACK% || exit /b 1 )
goto :eof

:cmd_reconfigure
echo Reconfigure = apply again using the current terraform.tfvars values.
if "%STACK%"=="all" (
  call :run_apply %STACK_1% || exit /b 1
  call :run_apply %STACK_2% || exit /b 1
  call :run_apply %STACK_3% || exit /b 1
) else ( call :run_apply %STACK% || exit /b 1 )
if /i "%STACK%"=="%STACK_2%" (
  echo.
  echo NOTE: running servers keep their OLD settings until they are replaced.
  echo       Run: scripts\run.bat redeploy
)
goto :eof

:cmd_redeploy
echo === REDEPLOY Keycloak servers ===
pushd "%ROOT_DIR%"
for /f "delims=" %%A in ('%TF_BIN% -chdir^=%STACK_2% output -raw autoscaling_group_name 2^>nul') do set "ASG=%%A"
for /f "delims=" %%A in ('%TF_BIN% -chdir^=%STACK_2% output -raw aws_region 2^>nul') do set "REGION=%%A"
popd
if "!ASG!"=="" (
  echo ERROR: could not read the Auto Scaling group name. Apply stack 2 first.
  exit /b 1
)
call :run_apply %STACK_2% || exit /b 1
echo Starting a rolling instance refresh on !ASG!
aws autoscaling start-instance-refresh --auto-scaling-group-name "!ASG!" --region "!REGION!" --preferences "{\"MinHealthyPercentage\":50,\"InstanceWarmup\":300}"
echo.
echo Watch it with:
echo    aws autoscaling describe-instance-refreshes --auto-scaling-group-name !ASG! --region !REGION!
goto :eof

:cmd_destroy
if "%STACK%"=="all" (
  call :confirm "This deletes EVERYTHING including the database and all Keycloak users." || goto :eof
  REM Reverse order: front door first, land last.
  call :run_destroy %STACK_3%
  call :run_destroy %STACK_2%
  call :run_destroy %STACK_1%
  goto :eof
)
if /i "%STACK%"=="%STACK_1%" call :confirm "Stack 1 holds the DATABASE. Destroying it deletes every realm, user and client. Destroy stacks 3 and 2 first." || goto :eof
if /i "%STACK%"=="%STACK_2%" call :confirm "This removes the Keycloak servers. Your data survives in the database. The site will be down until you apply stack 2 again." || goto :eof
if /i "%STACK%"=="%STACK_3%" call :confirm "This removes the load balancer. Keycloak keeps running but nobody can reach it. The public URL changes when you rebuild." || goto :eof
call :run_destroy %STACK%
goto :eof

:cmd_output
if "%STACK%"=="all" (
  call :run_output %STACK_1%
  call :run_output %STACK_2%
  call :run_output %STACK_3%
) else ( call :run_output %STACK% )
goto :eof

:cmd_status
echo === STATUS ===
pushd "%ROOT_DIR%"
echo|set /p="Database endpoint : "
%TF_BIN% -chdir=%STACK_1% output -raw database_endpoint 2>nul || echo not deployed
echo.
echo|set /p="Auto Scaling group: "
%TF_BIN% -chdir=%STACK_2% output -raw autoscaling_group_name 2>nul || echo not deployed
echo.
echo|set /p="Public URL        : "
%TF_BIN% -chdir=%STACK_3% output -raw keycloak_url 2>nul || echo not deployed
echo.
for /f "delims=" %%A in ('%TF_BIN% -chdir^=%STACK_3% output -raw target_group_arn 2^>nul') do set "TG=%%A"
for /f "delims=" %%A in ('%TF_BIN% -chdir^=%STACK_3% output -raw aws_region 2^>nul') do set "REGION=%%A"
popd
if not "!TG!"=="" (
  echo.
  echo Load balancer view of the servers:
  aws elbv2 describe-target-health --target-group-arn "!TG!" --region "!REGION!" --query "TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Why:TargetHealth.Reason}" --output table
)
goto :eof

:cmd_fmt
pushd "%ROOT_DIR%" && %TF_BIN% fmt -recursive & popd
echo Formatted.
goto :eof

:cmd_clean
call :confirm "Delete local .terraform folders and plan files? (Cloud resources are NOT touched.)" || goto :eof
for %%D in (%STACK_1% %STACK_2% %STACK_3%) do (
  if exist "%ROOT_DIR%\%%D\.terraform" rmdir /s /q "%ROOT_DIR%\%%D\.terraform"
  if exist "%ROOT_DIR%\%%D\tfplan.out" del /q "%ROOT_DIR%\%%D\tfplan.out"
  echo cleaned %%D
)
echo Local cache removed. Run init again before the next plan.
goto :eof

REM ===========================  helpers  =====================================

:banner
echo.
echo ------------------------------------------------------------
echo  %~1 %~2
echo ------------------------------------------------------------
goto :eof

:run_init
call :banner INIT %1
pushd "%ROOT_DIR%"
%TF_BIN% -chdir=%1 init -input=false -upgrade%EXTRA%
set "RC=!ERRORLEVEL!"
popd
exit /b !RC!

:ensure_init
if not exist "%ROOT_DIR%\%~1\.terraform" (
  echo First run for %~1 - initialising
  pushd "%ROOT_DIR%" && %TF_BIN% -chdir=%~1 init -input=false >nul & popd
)
goto :eof

:run_validate
call :banner VALIDATE %1
pushd "%ROOT_DIR%"
%TF_BIN% -chdir=%1 init -input=false -backend=false >nul
%TF_BIN% -chdir=%1 validate
set "RC=!ERRORLEVEL!"
popd
exit /b !RC!

:run_plan
call :banner PLAN %1
call :ensure_init %1
pushd "%ROOT_DIR%"
%TF_BIN% -chdir=%1 plan -input=false -out=tfplan.out%EXTRA%
set "RC=!ERRORLEVEL!"
popd
exit /b !RC!

:run_apply
call :banner APPLY %1
call :ensure_init %1
pushd "%ROOT_DIR%"
%TF_BIN% -chdir=%1 apply -input=false %APPROVE%%EXTRA%
set "RC=!ERRORLEVEL!"
popd
if not "!RC!"=="0" ( echo FAILED: %1 & exit /b !RC! )
echo OK: %1 applied
exit /b 0

:run_destroy
call :banner DESTROY %1
call :ensure_init %1
pushd "%ROOT_DIR%"
%TF_BIN% -chdir=%1 destroy -input=false %APPROVE%%EXTRA%
set "RC=!ERRORLEVEL!"
popd
if not "!RC!"=="0" ( echo FAILED: %1 & exit /b !RC! )
echo OK: %1 destroyed
exit /b 0

:run_output
call :banner OUTPUT %1
pushd "%ROOT_DIR%" && %TF_BIN% -chdir=%1 output & popd
goto :eof

:confirm
if "%AUTO_APPROVE%"=="1" exit /b 0
echo.
echo WARNING: %~1
set "ANSWER="
set /p "ANSWER=Type yes to continue: "
if /i "!ANSWER!"=="yes" exit /b 0
echo Cancelled - nothing was changed.
exit /b 1

:usage
echo.
for /f "tokens=1,* delims=:" %%A in ('findstr /n "^REM" "%~f0"') do (
  if %%A LEQ 26 (
    set "LINE=%%B"
    set "LINE=!LINE:~4!"
    echo(!LINE!
  )
)
goto :eof
