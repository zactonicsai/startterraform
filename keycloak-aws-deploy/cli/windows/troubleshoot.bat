@echo off
REM Diagnostics.  Usage: troubleshoot.bat [health|logs|shell|events|freeze|thaw]
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
set "CMD=%~1"
if "%CMD%"=="" set "CMD=health"

if /i "%CMD%"=="health" goto :health
if /i "%CMD%"=="logs"   goto :logs
if /i "%CMD%"=="shell"  goto :shell
if /i "%CMD%"=="events" goto :events
if /i "%CMD%"=="freeze" goto :freeze
if /i "%CMD%"=="thaw"   goto :thaw
echo Usage: %~nx0 [health^|logs^|shell^|events^|freeze^|thaw]
exit /b 1

:health
echo.
echo ==^> Target health
aws elbv2 describe-target-health --target-group-arn %TG_ARN% --query "TargetHealthDescriptions[].{T:Target.Id,S:TargetHealth.State,R:TargetHealth.Reason,D:TargetHealth.Description}" --output table
echo.
echo ==^> RDS status
aws rds describe-db-instances --db-instance-identifier %DB_ID% --query "DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,Endpoint:Endpoint.Address}" --output table
exit /b 0

:logs
echo.
echo ==^> Last 100 CloudWatch log lines from %LOG_GROUP%
for /f "usebackq delims=" %%S in (`aws logs describe-log-streams --log-group-name "%LOG_GROUP%" --order-by LastEventTime --descending --max-items 1 --query "logStreams[0].logStreamName" --output text`) do set "STREAM=%%S"
if "%STREAM%"=="None" ( echo [FAIL] No log streams yet. The container may not have started. & exit /b 1 )
echo   Stream: %STREAM%
aws logs get-log-events --log-group-name "%LOG_GROUP%" --log-stream-name "%STREAM%" --limit 100 --query "events[].message" --output text
exit /b 0

:shell
for /f "usebackq delims=" %%I in (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text`) do set "IID=%%I"
echo.
echo ==^> Opening an SSM session to %IID%
echo   Useful commands once inside:
echo     sudo tail -100 /var/log/keycloak-bootstrap.log
echo     sudo docker ps -a
echo     sudo docker logs keycloak --tail 100
echo     curl -s localhost:9000/health/ready
aws ssm start-session --target %IID%
exit /b 0

:events
echo.
echo ==^> Recent ASG activity
aws autoscaling describe-scaling-activities --auto-scaling-group-name %ASG_NAME% --max-records 15 --query "Activities[].{Time:StartTime,Status:StatusCode,Cause:Description}" --output table
echo.
echo ==^> Recent RDS events
aws rds describe-events --source-identifier %DB_ID% --source-type db-instance --duration 1440 --query "Events[].[Date,Message]" --output table
exit /b 0

:freeze
echo.
echo ==^> Suspending ReplaceUnhealthy + Terminate
aws autoscaling suspend-processes --auto-scaling-group-name %ASG_NAME% --scaling-processes ReplaceUnhealthy Terminate
echo   [ok] The ASG will now leave broken instances alone so you can investigate.
echo   [warn] Remember to run: troubleshoot.bat thaw
exit /b 0

:thaw
echo.
echo ==^> Resuming all ASG processes
aws autoscaling resume-processes --auto-scaling-group-name %ASG_NAME%
echo   [ok] Self-healing re-enabled.
exit /b 0
