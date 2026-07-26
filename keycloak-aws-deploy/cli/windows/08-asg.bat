@echo off
REM Creates the Auto Scaling Group, the scaling policy and the CloudWatch alarms.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%LT_ID%"=="" ( echo [FAIL] Run 07-launch-template.bat first. & exit /b 1 )

set "ASG_NAME=%PROJECT%-asg"
call "%HERE%lib\save.bat" ASG_NAME %ASG_NAME%

aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>nul | findstr /c:"%ASG_NAME%" >nul
if not errorlevel 1 (
  echo   [warn] ASG already exists - updating instead of creating
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name %ASG_NAME% --min-size %ASG_MIN% --max-size %ASG_MAX% --health-check-type ELB --health-check-grace-period 300
) else (
  echo.
  echo ==^> Creating the Auto Scaling Group
  echo   min=%ASG_MIN% max=%ASG_MAX% across 2 AZs, health checks from the ALB
  aws autoscaling create-auto-scaling-group ^
    --auto-scaling-group-name %ASG_NAME% ^
    --launch-template "LaunchTemplateId=%LT_ID%,Version=$Latest" ^
    --min-size %ASG_MIN% --max-size %ASG_MAX% --desired-capacity %ASG_MIN% ^
    --vpc-zone-identifier "%APP_A%,%APP_B%" ^
    --target-group-arns %TG_ARN% ^
    --health-check-type ELB ^
    --health-check-grace-period 300 ^
    --default-instance-warmup 300 ^
    --termination-policies OldestInstance ^
    --tags "Key=Name,Value=%PROJECT%-node,PropagateAtLaunch=true" "Key=Project,Value=%PROJECT%,PropagateAtLaunch=true"
  if errorlevel 1 ( echo [FAIL] ASG creation failed & exit /b 1 )
  echo   [ok] ASG created - instances are launching now
)

echo.
echo ==^> Adding a CPU target-tracking scaling policy ^(target 60%%^)
> "%HERE%state\policy.json" echo {"TargetValue":60.0,"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"DisableScaleIn":false}
aws autoscaling put-scaling-policy --auto-scaling-group-name %ASG_NAME% --policy-name %PROJECT%-cpu-target --policy-type TargetTrackingScaling --estimated-instance-warmup 300 --target-tracking-configuration file://"%HERE%state\policy.json" >nul
del /q "%HERE%state\policy.json"
echo   [ok] Works like a thermostat: 60%% leaves headroom for the ~3min boot

echo.
echo ==^> Creating CloudWatch alarms
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "'%ALB_ARN%' -replace '.*:loadbalancer/',''"`) do set "ALB_SUFFIX=%%S"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "'%TG_ARN%'.Split(':')[-1]"`) do set "TG_SUFFIX=%%S"

aws cloudwatch put-metric-alarm --alarm-name "%PROJECT%-NO-healthy-hosts-CRITICAL" --alarm-description "No healthy Keycloak instances - total outage" --namespace AWS/ApplicationELB --metric-name HealthyHostCount --statistic Minimum --period 60 --evaluation-periods 1 --threshold 1 --comparison-operator LessThanThreshold --treat-missing-data breaching --dimensions "Name=LoadBalancer,Value=%ALB_SUFFIX%" "Name=TargetGroup,Value=%TG_SUFFIX%" --tags "Key=Project,Value=%PROJECT%"
echo   [ok] %PROJECT%-NO-healthy-hosts-CRITICAL

aws cloudwatch put-metric-alarm --alarm-name "%PROJECT%-unhealthy-hosts" --alarm-description "At least one Keycloak instance is unhealthy" --namespace AWS/ApplicationELB --metric-name UnHealthyHostCount --statistic Average --period 60 --evaluation-periods 2 --threshold 0 --comparison-operator GreaterThanThreshold --treat-missing-data notBreaching --dimensions "Name=LoadBalancer,Value=%ALB_SUFFIX%" "Name=TargetGroup,Value=%TG_SUFFIX%" --tags "Key=Project,Value=%PROJECT%"
echo   [ok] %PROJECT%-unhealthy-hosts

aws cloudwatch put-metric-alarm --alarm-name "%PROJECT%-db-cpu-high" --alarm-description "RDS CPU above 80%% for 15 minutes" --namespace AWS/RDS --metric-name CPUUtilization --statistic Average --period 300 --evaluation-periods 3 --threshold 80 --comparison-operator GreaterThanThreshold --dimensions "Name=DBInstanceIdentifier,Value=%DB_ID%" --tags "Key=Project,Value=%PROJECT%"
echo   [ok] %PROJECT%-db-cpu-high

echo.
echo   [warn] Alarms have NO notification target. Attach an SNS topic with
echo   [warn] --alarm-actions or they will fire silently into the void.
echo.
echo ASG ready. Next: 09-dns.bat ^(or skip to 10-verify.bat^)
echo.
exit /b 0
