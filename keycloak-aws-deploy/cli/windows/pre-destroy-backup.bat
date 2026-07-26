@echo off
REM Takes a manual RDS snapshot and records an inventory. Run BEFORE destroying.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%DB_ID%"=="" ( echo [FAIL] No DB_ID in state. & exit /b 1 )

echo.
echo ==^> Confirming account and region
aws sts get-caller-identity --query "[Account,Arn]" --output text
echo   Region: %AWS_REGION%

echo.
echo ==^> Taking a manual RDS snapshot
echo   Automated backups die with the instance. Manual snapshots survive.
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "Get-Date -Format 'yyyyMMdd-HHmmss'"`) do set "STAMP=%%T"
set "SNAP=%PROJECT%-manual-%STAMP%"
aws rds create-db-snapshot --db-instance-identifier %DB_ID% --db-snapshot-identifier %SNAP% --tags "Key=Project,Value=%PROJECT%" "Key=Reason,Value=pre-teardown" >nul
if errorlevel 1 ( echo [FAIL] Snapshot creation failed & exit /b 1 )
call "%HERE%lib\save.bat" LAST_MANUAL_SNAPSHOT %SNAP%

echo   Waiting for the snapshot to complete ^(5-15 minutes^)...
aws rds wait db-snapshot-available --db-snapshot-identifier %SNAP%
echo   [ok] Snapshot available: %SNAP%

echo.
echo ==^> Recording a pre-destroy inventory
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=%PROJECT%" --query "ResourceTagMappingList[].ResourceARN" --output text > "%HERE%state\pre-destroy-inventory.txt"
echo   [ok] Recorded in state\pre-destroy-inventory.txt

echo.
echo ==^> Optional: export the Keycloak realm config
echo   A DB snapshot is opaque; a realm export is readable JSON you can
echo   diff and re-import into a completely different Keycloak.
for /f "usebackq delims=" %%I in (`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names %ASG_NAME% --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text`) do set "IID=%%I"
if not "%IID%"=="None" (
  echo.
  echo     aws ssm start-session --target %IID%
  echo     sudo docker exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/kc-export --users realm_file
  echo     sudo docker cp keycloak:/tmp/kc-export /tmp/kc-export
  echo.
)

echo.
echo Backups done. You may now run destroy-all.bat
echo.
exit /b 0
