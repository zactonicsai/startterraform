@echo off
REM Tears everything down in the correct dependency order: inside out.
REM Deliberately interactive. Read every prompt.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

for /f "usebackq delims=" %%A in (`aws sts get-caller-identity --query "Account" --output text`) do set "ACCOUNT=%%A"

echo ==============================================================
echo   DESTROY - Keycloak on AWS
echo   Project : %PROJECT%
echo   Region  : %AWS_REGION%
echo   Account : %ACCOUNT%
echo ==============================================================
echo.
echo   Order ^(each depends on the previous^):
echo     1. ASG to zero, wait for instances to drain
echo     2. Delete ASG
echo     3. Delete launch template
echo     4. Delete ALB listeners
echo     5. Delete ALB, wait for network interfaces to release
echo     6. Delete target group
echo     7. RDS: disable deletion protection, delete WITH final snapshot
echo     8. Delete DB subnet group
echo     9. Delete NAT gateways, wait
echo    10. Release Elastic IPs
echo    11. Delete route tables and subnets
echo    12. Detach + delete internet gateway
echo    13. Revoke cross-referencing SG rules, delete security groups
echo    14. Delete VPC
echo    15. IAM role + instance profile
echo    16. Schedule secret deletion
echo    17. Route 53 record, log groups, alarms
echo.
echo   [warn] Have you run pre-destroy-backup.bat ?
echo.
call "%HERE%lib\confirm.bat" "Type the project name to confirm you mean THIS stack:" "%PROJECT%" || exit /b 1
call "%HERE%lib\confirm.bat" "Last chance. Type DESTROY:" DESTROY || exit /b 1

REM ---------- 1-2. ASG ----------
if "%ASG_NAME%"=="" goto :skipasg
echo.
echo ==^> 1. Scaling the ASG to zero
aws autoscaling update-auto-scaling-group --auto-scaling-group-name %ASG_NAME% --min-size 0 --max-size 0 --desired-capacity 0 2>nul
if errorlevel 1 ( echo   [warn] ASG not found & goto :skipasg )
set /a DN=0
:drainloop
set /a DN+=1
for /f "usebackq delims=" %%C in (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "length(AutoScalingGroups[0].Instances)" --output text`) do set "CNT=%%C"
echo   instances remaining: %CNT%
if "%CNT%"=="0" goto :drained
if %DN% GEQ 60 goto :drained
timeout /t 15 /nobreak >nul
goto :drainloop
:drained
echo   [ok] Drained
echo.
echo ==^> 2. Deleting the ASG
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name %ASG_NAME% --force-delete
:skipasg

REM ---------- 3. launch template ----------
if "%LT_ID%"=="" goto :skiplt
echo.
echo ==^> 3. Deleting the launch template
aws ec2 delete-launch-template --launch-template-id %LT_ID% >nul 2>nul
:skiplt

REM ---------- 4-6. ALB ----------
if "%HTTPS_LISTENER%"=="" goto :skiplisteners
echo.
echo ==^> 4. Deleting listeners
aws elbv2 delete-listener --listener-arn %HTTPS_LISTENER% >nul 2>nul
if not "%HTTP_LISTENER%"=="" aws elbv2 delete-listener --listener-arn %HTTP_LISTENER% >nul 2>nul
:skiplisteners

if "%ALB_ARN%"=="" goto :skipalb
echo.
echo ==^> 5. Deleting the load balancer
aws elbv2 modify-load-balancer-attributes --load-balancer-arn %ALB_ARN% --attributes Key=deletion_protection.enabled,Value=false >nul 2>nul
aws elbv2 delete-load-balancer --load-balancer-arn %ALB_ARN% >nul 2>nul
echo   Waiting for the ALB and its network interfaces to release...
aws elbv2 wait load-balancers-deleted --load-balancer-arns %ALB_ARN% 2>nul
echo   Extra 60s grace - ENIs linger after the API reports 'deleted'.
echo   Skipping this wait is the #1 cause of DependencyViolation errors later.
timeout /t 60 /nobreak >nul
echo   [ok] ALB gone
:skipalb

if "%TG_ARN%"=="" goto :skiptg
echo.
echo ==^> 6. Deleting the target group
aws elbv2 delete-target-group --target-group-arn %TG_ARN% >nul 2>nul
:skiptg

REM ---------- 7-8. RDS ----------
if "%DB_ID%"=="" goto :skiprds
aws rds describe-db-instances --db-instance-identifier %DB_ID% >nul 2>nul
if errorlevel 1 goto :skiprds

echo.
echo ==^> 7. Deleting the RDS database
echo.
echo   This is the only irreplaceable resource in the stack.
echo.
echo     snapshot  - delete but take a final snapshot first  ^(recommended^)
echo     nuke      - delete with NO snapshot                 ^(permanent^)
echo     keep      - leave the database running              ^(skip^)
echo.
set "CHOICE="
set /p "CHOICE=Choose [snapshot/nuke/keep]: "

if /i "%CHOICE%"=="keep" (
  echo   [warn] Database kept. It keeps costing money ^(~$130/mo Multi-AZ^).
  echo   [warn] Its subnet group and security group cannot be deleted while it exists.
  goto :skiprds
)
if /i not "%CHOICE%"=="snapshot" if /i not "%CHOICE%"=="nuke" (
  echo [FAIL] Unrecognised choice. Nothing deleted. Re-run when ready.
  exit /b 1
)

echo   Removing deletion protection ^(a deliberate act^)...
aws rds modify-db-instance --db-instance-identifier %DB_ID% --no-deletion-protection --apply-immediately >nul
aws rds wait db-instance-available --db-instance-identifier %DB_ID%
echo   [ok] Deletion protection off

if /i "%CHOICE%"=="snapshot" (
  for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "STAMP=%%T"
  set "FINAL=%PROJECT%-final-%STAMP%"
  aws rds delete-db-instance --db-instance-identifier %DB_ID% --final-db-snapshot-identifier %PROJECT%-final-%STAMP% >nul
  call "%HERE%lib\save.bat" FINAL_SNAPSHOT %PROJECT%-final-%STAMP%
  echo.
  echo   Final snapshot: %PROJECT%-final-%STAMP%
  echo   WRITE THAT DOWN. Keep the DB secret at least as long as the snapshot,
  echo   or you will have an encrypted box you cannot open.
  echo.
) else (
  call "%HERE%lib\confirm.bat" "Permanent deletion, no backup. Type NUKE:" NUKE || exit /b 1
  aws rds delete-db-instance --db-instance-identifier %DB_ID% --skip-final-snapshot --delete-automated-backups >nul
  echo   [warn] No snapshot taken. This data is gone forever.
)

echo   Waiting for deletion ^(10-20 min if taking a final snapshot^)...
aws rds wait db-instance-deleted --db-instance-identifier %DB_ID% 2>nul
echo   [ok] Database deleted
echo.
echo ==^> 8. Deleting the DB subnet group
aws rds delete-db-subnet-group --db-subnet-group-name %DB_SUBNET_GROUP% >nul 2>nul
:skiprds

REM ---------- 9-10. NAT + EIP ----------
if "%NAT_A%"=="" goto :skipnat
echo.
echo ==^> 9. Deleting NAT gateways ^(the expensive ones - ~$35/mo each^)
aws ec2 delete-nat-gateway --nat-gateway-id %NAT_A% >nul 2>nul
if not "%NAT_B%"=="%NAT_A%" if not "%NAT_B%"=="" aws ec2 delete-nat-gateway --nat-gateway-id %NAT_B% >nul 2>nul
echo   Waiting for deletion ^(2-5 minutes^)...
if "%NAT_A%"=="%NAT_B%" (
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids %NAT_A% 2>nul
) else (
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids %NAT_A% %NAT_B% 2>nul
)
echo   [ok] NAT gateways gone
:skipnat

echo.
echo ==^> 10. Releasing Elastic IPs ^(an idle EIP still costs ~$3.60/mo^)
echo   Order matters: you cannot release an EIP attached to a live NAT gateway.
if not "%EIP_A%"=="" aws ec2 release-address --allocation-id %EIP_A% >nul 2>nul && echo   [ok] released %EIP_A%
if not "%EIP_B%"=="" aws ec2 release-address --allocation-id %EIP_B% >nul 2>nul && echo   [ok] released %EIP_B%

REM ---------- 11. route tables + subnets ----------
echo.
echo ==^> 11. Deleting route tables
for %%R in (%RTB_PUB% %RTB_A% %RTB_B%) do call :delrtb %%R
echo.
echo ==^> 11b. Deleting subnets
for %%S in (%PUB_A% %PUB_B% %APP_A% %APP_B% %DB_A% %DB_B%) do (
  aws ec2 delete-subnet --subnet-id %%S >nul 2>nul && echo   [ok] deleted %%S || echo   [warn] could not delete %%S
)

REM ---------- 12. IGW ----------
if "%IGW_ID%"=="" goto :skipigw
echo.
echo ==^> 12. Detaching and deleting the internet gateway
aws ec2 detach-internet-gateway --internet-gateway-id %IGW_ID% --vpc-id %VPC_ID% >nul 2>nul
aws ec2 delete-internet-gateway --internet-gateway-id %IGW_ID% >nul 2>nul
:skipigw

REM ---------- 13. security groups ----------
echo.
echo ==^> 13. Revoking cross-references, then deleting security groups
echo   They reference each other, so the rules must go before the groups.
if not "%SG_RDS%"=="" if not "%SG_APP%"=="" call :revoke %SG_RDS% 5432 5432 %SG_APP%
if not "%SG_APP%"=="" if not "%SG_ALB%"=="" call :revoke %SG_APP% 8080 8080 %SG_ALB%
if not "%SG_APP%"=="" if not "%SG_ALB%"=="" call :revoke %SG_APP% 9000 9000 %SG_ALB%
if not "%SG_APP%"=="" call :revoke %SG_APP% 7800 7801 %SG_APP%
for %%G in (%SG_RDS% %SG_APP% %SG_ALB%) do call :delsg %%G

REM ---------- 14. VPC ----------
if "%VPC_ID%"=="" goto :skipvpc
echo.
echo ==^> 14. Deleting the VPC
aws ec2 delete-vpc --vpc-id %VPC_ID% 2>nul
if errorlevel 1 (
  echo   [warn] VPC would not delete - something is still inside it.
  echo   Leftover network interfaces:
  aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=%VPC_ID%" --query "NetworkInterfaces[].[NetworkInterfaceId,Description,Status]" --output table
  echo   Wait a few minutes and re-run this script.
) else (
  echo   [ok] VPC deleted
)
:skipvpc

REM ---------- 15. IAM ----------
if "%ROLE_NAME%"=="" goto :skipiam
echo.
echo ==^> 15. Deleting the IAM role and instance profile
echo   Order: remove role from profile -^> delete profile -^> detach policies -^> delete role
aws iam remove-role-from-instance-profile --instance-profile-name %ROLE_NAME% --role-name %ROLE_NAME% >nul 2>nul
aws iam delete-instance-profile --instance-profile-name %ROLE_NAME% >nul 2>nul
aws iam delete-role-policy --role-name %ROLE_NAME% --policy-name %PROJECT%-read-secrets >nul 2>nul
aws iam detach-role-policy --role-name %ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >nul 2>nul
aws iam detach-role-policy --role-name %ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy >nul 2>nul
aws iam delete-role --role-name %ROLE_NAME% >nul 2>nul && echo   [ok] role deleted
:skipiam

REM ---------- 16. secrets ----------
echo.
echo ==^> 16. Scheduling secret deletion
echo   Keeping the DB credentials for 30 days on purpose: if you ever restore
echo   the final snapshot you will need that master password.
if not "%DB_SECRET_ARN%"==""  aws secretsmanager delete-secret --secret-id %DB_SECRET_ARN%  --recovery-window-in-days 30 >nul 2>nul && echo   [ok] db secret scheduled (30d)
if not "%ART_SECRET_ARN%"=="" aws secretsmanager delete-secret --secret-id %ART_SECRET_ARN% --recovery-window-in-days 7 >nul 2>nul && echo   [ok] artifactory secret scheduled (7d)
if not "%KC_SECRET_ARN%"==""  aws secretsmanager delete-secret --secret-id %KC_SECRET_ARN%  --recovery-window-in-days 7 >nul 2>nul && echo   [ok] bootstrap secret scheduled (7d)

REM ---------- 17. DNS, logs, alarms ----------
if /i not "%DNS_RECORD_CREATED%"=="yes" goto :skipdns
if "%HOSTED_ZONE_ID%"=="" goto :skipdns
echo.
echo ==^> 17. Deleting the Route 53 alias record
> "%HERE%state\del.json" echo {"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"%DOMAIN_NAME%","Type":"A","AliasTarget":{"HostedZoneId":"%ALB_ZONE%","DNSName":"%ALB_DNS%","EvaluateTargetHealth":true}}}]}
aws route53 change-resource-record-sets --hosted-zone-id %HOSTED_ZONE_ID% --change-batch file://"%HERE%state\del.json" >nul 2>nul && echo   [ok] record deleted
del /q "%HERE%state\del.json" 2>nul
:skipdns

echo.
echo ==^> 17b. Deleting CloudWatch log groups
echo   The Docker awslogs driver may have auto-created these. Default
echo   retention is 'never expire', so they cost money indefinitely.
aws logs delete-log-group --log-group-name "%LOG_GROUP%" >nul 2>nul && echo   [ok] %LOG_GROUP%
aws logs delete-log-group --log-group-name "/aws/vpc/%PROJECT%/flow-logs" >nul 2>nul

echo.
echo ==^> 17c. Deleting alarms
aws cloudwatch delete-alarms --alarm-names "%PROJECT%-NO-healthy-hosts-CRITICAL" "%PROJECT%-unhealthy-hosts" "%PROJECT%-db-cpu-high" >nul 2>nul && echo   [ok] alarms deleted

for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "STAMP=%%T"
move /y "%STATE_FILE%" "%STATE_FILE%.destroyed-%STAMP%" >nul 2>nul

echo.
echo Teardown complete.
echo.
echo   Next, and do not skip this:
echo     orphan-hunt.bat        find anything still billing
echo     check the bill in 48h  AWS billing data lags by up to a day
echo.
echo   Deliberately kept:
echo     - RDS snapshots ^(manual + final^)   ~$0.095/GB-month
echo     - Secrets in their recovery window
echo   Delete those separately once you are certain you will not need them.
echo.
exit /b 0

:delrtb
if "%~1"=="" exit /b 0
for /f "usebackq delims=" %%A in (`aws ec2 describe-route-tables --route-table-ids %~1 --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text 2^>nul`) do (
  for %%B in (%%A) do aws ec2 disassociate-route-table --association-id %%B >nul 2>nul
)
aws ec2 delete-route-table --route-table-id %~1 >nul 2>nul && echo   [ok] deleted %~1 || echo   [warn] could not delete %~1
exit /b 0

:revoke
aws ec2 revoke-security-group-ingress --group-id %~1 --ip-permissions "IpProtocol=tcp,FromPort=%~2,ToPort=%~3,UserIdGroupPairs=[{GroupId=%~4}]" >nul 2>nul && echo   [ok] revoked %~2 on %~1
exit /b 0

:delsg
if "%~1"=="" exit /b 0
for /l %%N in (1,1,6) do (
  aws ec2 delete-security-group --group-id %~1 >nul 2>nul
  if not errorlevel 1 ( echo   [ok] deleted %~1 & exit /b 0 )
  echo   [warn] DependencyViolation on %~1 - leftover ENI still using it. Retry %%N/6 in 30s
  timeout /t 30 /nobreak >nul
)
echo   [warn] gave up on %~1 - re-run this script in a few minutes
exit /b 0
