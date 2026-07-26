@echo off
REM Chaos tests. Untested fault tolerance is just a hope.
REM Usage: test-failover.bat [kill-instance|kill-container|db-failover|watch]
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
set "CMD=%~1"
if "%CMD%"=="" set "CMD=watch"

if /i "%CMD%"=="kill-instance"  goto :killinst
if /i "%CMD%"=="kill-container" goto :killcont
if /i "%CMD%"=="db-failover"    goto :dbfail
if /i "%CMD%"=="watch"          goto :watch
echo Usage: %~nx0 [kill-instance^|kill-container^|db-failover^|watch]
exit /b 1

:hint
echo.
echo   Run this in a SECOND window first, so you can see the user impact:
echo.
echo     powershell -NoProfile -Command "while($true){try{(Invoke-WebRequest -UseBasicParsing 'https://%DOMAIN_NAME%/realms/master').StatusCode}catch{'ERR'};Start-Sleep 1}"
echo.
echo   You want an unbroken stream of 200s throughout the test.
echo.
exit /b 0

:killinst
call :hint
call "%HERE%lib\confirm.bat" "Terminate one instance? Type yes:" yes || exit /b 1
for /f "usebackq delims=" %%I in (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text`) do set "VICTIM=%%I"
echo.
echo ==^> Terminating %VICTIM%
aws ec2 terminate-instances --instance-ids %VICTIM% >nul
echo   [ok] Expected: no user-visible errors; replacement healthy in 3-5 min.
echo   If you DO see errors: ASG_MIN was 1, or both instances were in one AZ.
goto :watch

:killcont
call :hint
echo   This breaks the APP but leaves the VM healthy. It proves your ASG
echo   health-check-type is ELB and not EC2 - an EC2 check cannot see this.
for /f "usebackq delims=" %%I in (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text`) do set "VICTIM=%%I"
call "%HERE%lib\confirm.bat" "Stop the Keycloak container on %VICTIM%? Type yes:" yes || exit /b 1
> "%HERE%state\cmd.json" echo {"commands":["docker stop keycloak"]}
aws ssm send-command --instance-ids %VICTIM% --document-name "AWS-RunShellScript" --parameters file://"%HERE%state\cmd.json" --query "Command.CommandId" --output text
del /q "%HERE%state\cmd.json"
echo   [ok] Expected: unhealthy in ~45s ^(3 x 15s^), replaced a few minutes later.
goto :watch

:dbfail
call :hint
echo   [warn] Expect 60-120s of database errors. This is the real Multi-AZ test.
call "%HERE%lib\confirm.bat" "Force an RDS failover? Type yes:" yes || exit /b 1
aws rds reboot-db-instance --db-instance-identifier %DB_ID% --force-failover >nul
echo   [ok] Failover triggered.
timeout /t 30 /nobreak >nul
aws rds describe-events --source-identifier %DB_ID% --source-type db-instance --duration 20 --query "Events[].[Date,Message]" --output table
echo.
echo   Afterwards, check whether instances RECOVERED or were all REPLACED.
echo   Fleet-wide replacement after a 90s blip means your unhealthy threshold
echo   is too aggressive, and a brief degradation became a full outage.
exit /b 0

:watch
echo.
echo ==^> Watching target health - Ctrl-C to stop
:watchloop
cls
echo %TIME%  target group health
aws elbv2 describe-target-health --target-group-arn %TG_ARN% --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" --output table
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Count:length(Instances)}" --output table
timeout /t 15 /nobreak >nul
goto :watchloop
