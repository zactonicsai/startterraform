@echo off
REM End-to-end verification. Safe to run repeatedly.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

echo.
echo ==^> ASG instances
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}" --output table

echo.
echo ==^> Target group health ^(the number that actually matters^)
aws elbv2 describe-target-health --target-group-arn %TG_ARN% --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}" --output table

for /f "usebackq delims=" %%H in (`aws elbv2 describe-target-health --target-group-arn %TG_ARN% --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text`) do set "HEALTHY=%%H"
echo   Healthy targets: %HEALTHY%

if "%HEALTHY%"=="0" (
  echo.
  echo   [warn] No healthy targets yet.
  echo   First boot takes 4-6 minutes ^(image pull + JVM start + schema creation^).
  echo   If it stays at 0, check in this order:
  echo     1. KC_HEALTH_ENABLED=true in the user-data     ^(most common cause^)
  echo     2. app SG allows port 9000 from the ALB SG
  echo     3. health-check-grace-period is at least 300
  echo     4. read the boot log:  troubleshoot.bat logs
)

echo.
echo ==^> Recent scaling activity
aws autoscaling describe-scaling-activities --auto-scaling-group-name %ASG_NAME% --max-records 5 --query "Activities[].{Status:StatusCode,Cause:Description}" --output table

echo.
echo ==^> Keycloak OIDC discovery document
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "try { (Invoke-RestMethod -TimeoutSec 15 'https://%DOMAIN_NAME%/realms/master/.well-known/openid-configuration').issuer } catch { '' }"`) do set "ISSUER=%%I"
if "%ISSUER%"=="https://%DOMAIN_NAME%/realms/master" (
  echo   [ok] Issuer is correct: %ISSUER%
) else (
  if "%ISSUER%"=="" (
    echo   [warn] Could not fetch the discovery document yet.
    echo   Try the ALB directly: https://%ALB_DNS%/realms/master
  ) else (
    echo   [warn] Issuer is WRONG: %ISSUER%
    echo   Expected: https://%DOMAIN_NAME%/realms/master
    echo   Fix KC_HOSTNAME, re-run 07-launch-template.bat, then refresh instances.
  )
)

echo.
echo   Admin console: https://%DOMAIN_NAME%/admin
echo.
echo   Bootstrap credentials:
echo     aws secretsmanager get-secret-value --secret-id "%KC_SECRET_ARN%" --query SecretString --output text
echo.
echo   Do this immediately after your first login:
echo     1. create a real named admin account and enable OTP/MFA on it
echo     2. delete the 'tmpadmin' bootstrap user
echo     3. delete the bootstrap secret
echo     4. create a separate realm for your apps - never use 'master'
echo.
exit /b 0
