@echo off
REM Creates a Route 53 alias record pointing DOMAIN_NAME at the ALB.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%ALB_DNS%"=="" ( echo [FAIL] Run 06-alb.bat first. & exit /b 1 )

if "%ROUTE53_ZONE_NAME%"=="" (
  echo   [warn] ROUTE53_ZONE_NAME is blank - skipping DNS.
  echo   Point %DOMAIN_NAME% at %ALB_DNS% yourself.
  exit /b 0
)

echo.
echo ==^> Looking up the hosted zone for %ROUTE53_ZONE_NAME%
for /f "usebackq delims=" %%Z in (`aws route53 list-hosted-zones-by-name --dns-name "%ROUTE53_ZONE_NAME%" --query "HostedZones[?Name=='%ROUTE53_ZONE_NAME%.'].Id | [0]" --output text`) do set "RAWZONE=%%Z"
if "%RAWZONE%"=="" ( echo [FAIL] Hosted zone not found & exit /b 1 )
if "%RAWZONE%"=="None" ( echo [FAIL] Hosted zone not found & exit /b 1 )
for /f "usebackq delims=" %%Z in (`powershell -NoProfile -Command "'%RAWZONE%' -replace '/hostedzone/',''"`) do set "HOSTED_ZONE_ID=%%Z"
call "%HERE%lib\save.bat" HOSTED_ZONE_ID %HOSTED_ZONE_ID%

echo.
echo ==^> Creating an A/ALIAS record: %DOMAIN_NAME% -^> %ALB_DNS%
echo   ALIAS not CNAME: free to query, works at the zone apex, tracks the
echo   ALB's changing IP addresses automatically.
> "%HERE%state\dns.json" echo {"Comment":"Keycloak ALB alias for %PROJECT%","Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%DOMAIN_NAME%","Type":"A","AliasTarget":{"HostedZoneId":"%ALB_ZONE%","DNSName":"%ALB_DNS%","EvaluateTargetHealth":true}}}]}
for /f "usebackq delims=" %%C in (`aws route53 change-resource-record-sets --hosted-zone-id %HOSTED_ZONE_ID% --change-batch file://"%HERE%state\dns.json" --query "ChangeInfo.Id" --output text`) do set "CHANGEID=%%C"
del /q "%HERE%state\dns.json"
if "%CHANGEID%"=="" ( echo [FAIL] DNS change failed & exit /b 1 )
call "%HERE%lib\save.bat" DNS_RECORD_CREATED yes
echo   [ok] Change submitted: %CHANGEID%

echo.
echo ==^> Waiting for the change to propagate across Route 53
aws route53 wait resource-record-sets-changed --id %CHANGEID%
echo   [ok] DNS live
echo.
echo DNS ready. Next: 10-verify.bat
echo.
exit /b 0
