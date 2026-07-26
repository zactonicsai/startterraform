@echo off
REM Creates the ALB, the target group with health checks, and both listeners.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%SG_ALB%"=="" ( echo [FAIL] Run 02-security-groups.bat first. & exit /b 1 )

if not "%ALB_ARN%"=="" (
  echo   [warn] ALB already recorded - skipping
) else (
  echo.
  echo ==^> Creating the Application Load Balancer
  for /f "usebackq delims=" %%A in (`aws elbv2 create-load-balancer --name %PROJECT%-alb --type application --scheme internet-facing --ip-address-type ipv4 --subnets %PUB_A% %PUB_B% --security-groups %SG_ALB% --tags "Key=Project,Value=%PROJECT%" --query "LoadBalancers[0].LoadBalancerArn" --output text`) do set "ALB_ARN=%%A"
  if "%ALB_ARN%"=="" ( echo [FAIL] ALB creation failed & exit /b 1 )
  call "%HERE%lib\save.bat" ALB_ARN %ALB_ARN%
)

for /f "usebackq delims=" %%D in (`aws elbv2 describe-load-balancers --load-balancer-arns %ALB_ARN% --query "LoadBalancers[0].DNSName" --output text`) do set "ALB_DNS=%%D"
call "%HERE%lib\save.bat" ALB_DNS %ALB_DNS%
for /f "usebackq delims=" %%Z in (`aws elbv2 describe-load-balancers --load-balancer-arns %ALB_ARN% --query "LoadBalancers[0].CanonicalHostedZoneId" --output text`) do set "ALB_ZONE=%%Z"
call "%HERE%lib\save.bat" ALB_ZONE %ALB_ZONE%

echo.
echo ==^> Applying ALB hardening attributes
aws elbv2 modify-load-balancer-attributes --load-balancer-arn %ALB_ARN% --attributes Key=routing.http.drop_invalid_header_fields.enabled,Value=true Key=idle_timeout.timeout_seconds,Value=120 >nul
echo   [ok] Invalid headers dropped, idle timeout 120s

if not "%TG_ARN%"=="" (
  echo   [warn] Target group already recorded - skipping
) else (
  echo.
  echo ==^> Creating the target group
  echo   Traffic on 8080, health checks on 9000 /health/ready
  for /f "usebackq delims=" %%T in (`aws elbv2 create-target-group --name %PROJECT%-tg --protocol HTTP --port 8080 --vpc-id %VPC_ID% --target-type instance --health-check-protocol HTTP --health-check-port 9000 --health-check-path /health/ready --health-check-interval-seconds 15 --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --matcher HttpCode=200 --tags "Key=Project,Value=%PROJECT%" --query "TargetGroups[0].TargetGroupArn" --output text`) do set "TG_ARN=%%T"
  if "%TG_ARN%"=="" ( echo [FAIL] target group creation failed & exit /b 1 )
  call "%HERE%lib\save.bat" TG_ARN %TG_ARN%
)

echo.
echo ==^> Enabling sticky sessions and a graceful deregistration delay
aws elbv2 modify-target-group-attributes --target-group-arn %TG_ARN% --attributes Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie Key=stickiness.lb_cookie.duration_seconds,Value=3600 Key=deregistration_delay.timeout_seconds,Value=60 >nul
echo   [ok] Sticky for 1h, 60s drain on removal

if not "%HTTPS_LISTENER%"=="" (
  echo   [warn] HTTPS listener already recorded - skipping
) else (
  echo.
  echo ==^> Creating the HTTPS listener ^(TLS 1.2/1.3 only^)
  for /f "usebackq delims=" %%L in (`aws elbv2 create-listener --load-balancer-arn %ALB_ARN% --protocol HTTPS --port 443 --certificates "CertificateArn=%ACM_CERT_ARN%" --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 --default-actions "Type=forward,TargetGroupArn=%TG_ARN%" --query "Listeners[0].ListenerArn" --output text`) do set "HTTPS_LISTENER=%%L"
  call "%HERE%lib\save.bat" HTTPS_LISTENER %HTTPS_LISTENER%
)

if not "%HTTP_LISTENER%"=="" (
  echo   [warn] HTTP listener already recorded - skipping
) else (
  echo.
  echo ==^> Creating the HTTP listener ^(301 redirect to HTTPS^)
  > "%HERE%state\redirect.json" echo [{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]
  for /f "usebackq delims=" %%L in (`aws elbv2 create-listener --load-balancer-arn %ALB_ARN% --protocol HTTP --port 80 --default-actions file://"%HERE%state\redirect.json" --query "Listeners[0].ListenerArn" --output text`) do set "HTTP_LISTENER=%%L"
  del /q "%HERE%state\redirect.json"
  call "%HERE%lib\save.bat" HTTP_LISTENER %HTTP_LISTENER%
)

echo.
echo   ALB address: %ALB_DNS%
echo.
echo Load balancer ready. Next: 07-launch-template.bat
echo.
exit /b 0
