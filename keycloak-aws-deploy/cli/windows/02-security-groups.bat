@echo off
REM Creates the three chained security groups: ALB -> App -> RDS.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%VPC_ID%"=="" ( echo [FAIL] No VPC_ID in state. Run 01-network.bat first. & exit /b 1 )

echo.
echo ==^> Creating security groups
call :mksg SG_ALB %PROJECT%-alb-sg "Public HTTPS entry point"
call :mksg SG_APP %PROJECT%-app-sg "Keycloak EC2 instances"
call :mksg SG_RDS %PROJECT%-rds-sg "PostgreSQL - app tier only"

echo.
echo ==^> ALB rules: HTTPS + HTTP from the internet
call :allowcidr %SG_ALB% 443 0.0.0.0/0 "HTTPS from internet"
call :allowcidr %SG_ALB% 80  0.0.0.0/0 "HTTP for redirect to HTTPS"

echo.
echo ==^> App rules: only from the ALB, plus cluster gossip between nodes
call :allowsg %SG_APP% 8080 8080 %SG_ALB% "App traffic from ALB only"
call :allowsg %SG_APP% 9000 9000 %SG_ALB% "Health checks from ALB"
call :allowsg %SG_APP% 7800 7801 %SG_APP% "Infinispan/JGroups cluster"

echo.
echo ==^> RDS rules: PostgreSQL only from the app tier
call :allowsg %SG_RDS% 5432 5432 %SG_APP% "PostgreSQL from Keycloak nodes"

echo.
echo   Note: no port 22 rule. Shell access is via SSM Session Manager.
echo.
echo Security groups ready. Next: 03-secrets.bat
echo.
exit /b 0

:mksg
call set "_EXIST=%%%~1%%"
if not "%_EXIST%"=="" ( echo   [warn] %~1 exists - skipping & exit /b 0 )
for /f "usebackq delims=" %%I in (`aws ec2 create-security-group --group-name %~2 --description %~3 --vpc-id %VPC_ID% --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=%~2},{Key=Project,Value=%PROJECT%}]" --query "GroupId" --output text`) do set "_GID=%%I"
if "%_GID%"=="" ( echo [FAIL] security group %~2 creation failed & exit /b 1 )
call "%HERE%lib\save.bat" %~1 %_GID%
set "_GID="
exit /b 0

:allowcidr
REM %1=SG %2=PORT %3=CIDR %4=DESC
aws ec2 authorize-security-group-ingress --group-id %~1 --ip-permissions "IpProtocol=tcp,FromPort=%~2,ToPort=%~2,IpRanges=[{CidrIp=%~3,Description=%~4}]" >nul 2>nul
if errorlevel 1 ( echo   [warn] rule already present: %~4 ) else ( echo   [ok] %~4 )
exit /b 0

:allowsg
REM %1=SG %2=FROMPORT %3=TOPORT %4=SRCSG %5=DESC
aws ec2 authorize-security-group-ingress --group-id %~1 --ip-permissions "IpProtocol=tcp,FromPort=%~2,ToPort=%~3,UserIdGroupPairs=[{GroupId=%~4,Description=%~5}]" >nul 2>nul
if errorlevel 1 ( echo   [warn] rule already present: %~5 ) else ( echo   [ok] %~5 )
exit /b 0
