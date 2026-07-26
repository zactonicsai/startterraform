@echo off
REM Creates the Multi-AZ PostgreSQL database. Slowest step: 10-20 minutes.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%SG_RDS%"=="" ( echo [FAIL] Run 02-security-groups.bat first. & exit /b 1 )
if "%DB_SECRET_ARN%"=="" ( echo [FAIL] Run 03-secrets.bat first. & exit /b 1 )

set "DB_ID=%PROJECT%-db"
call "%HERE%lib\save.bat" DB_ID %DB_ID%
call "%HERE%lib\save.bat" DB_SUBNET_GROUP %PROJECT%-db-subnets

echo.
echo ==^> Creating the DB subnet group ^(needs 2+ AZs for Multi-AZ^)
aws rds create-db-subnet-group --db-subnet-group-name %PROJECT%-db-subnets --db-subnet-group-description "Private data subnets for Keycloak" --subnet-ids %DB_A% %DB_B% --tags "Key=Project,Value=%PROJECT%" >nul 2>nul
if errorlevel 1 ( echo   [warn] Subnet group already exists ) else ( echo   [ok] Subnet group created )

aws rds describe-db-instances --db-instance-identifier %DB_ID% >nul 2>nul
if not errorlevel 1 (
  echo   [warn] Database %DB_ID% already exists - skipping creation
  goto :waitdb
)

echo.
echo ==^> Reading the master password back out of Secrets Manager
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(aws secretsmanager get-secret-value --secret-id '%DB_SECRET_ARN%' --query SecretString --output text ^| ConvertFrom-Json).password"`) do set "DB_PASSWORD=%%P"
if "%DB_PASSWORD%"=="" ( echo [FAIL] Could not read the database password. & exit /b 1 )
echo   [ok] Retrieved

set "MULTIAZ=--multi-az"
if /i not "%DB_MULTI_AZ%"=="true" set "MULTIAZ=--no-multi-az"
set /a MAXSTORE=%DB_ALLOCATED_STORAGE% * 5

echo.
echo ==^> Creating RDS instance %DB_ID% ^(10-20 minutes^)
echo   Multi-AZ: %DB_MULTI_AZ%   Class: %DB_INSTANCE_CLASS%   Storage: %DB_ALLOCATED_STORAGE%GB gp3
aws rds create-db-instance ^
  --db-instance-identifier %DB_ID% ^
  --db-instance-class %DB_INSTANCE_CLASS% ^
  --engine postgres ^
  --engine-version 16 ^
  --master-username kcadmin ^
  --master-user-password "%DB_PASSWORD%" ^
  --db-name keycloak ^
  --allocated-storage %DB_ALLOCATED_STORAGE% ^
  --max-allocated-storage %MAXSTORE% ^
  --storage-type gp3 ^
  --storage-encrypted ^
  %MULTIAZ% ^
  --db-subnet-group-name %PROJECT%-db-subnets ^
  --vpc-security-group-ids %SG_RDS% ^
  --no-publicly-accessible ^
  --backup-retention-period %DB_BACKUP_RETENTION% ^
  --preferred-backup-window "03:00-04:00" ^
  --preferred-maintenance-window "sun:04:30-sun:05:30" ^
  --auto-minor-version-upgrade ^
  --deletion-protection ^
  --enable-performance-insights ^
  --copy-tags-to-snapshot ^
  --enable-cloudwatch-logs-exports postgresql upgrade ^
  --tags "Key=Project,Value=%PROJECT%" >nul
if errorlevel 1 ( echo [FAIL] RDS creation failed & exit /b 1 )
echo   [ok] Creation started
set "DB_PASSWORD="

:waitdb
echo.
echo ==^> Waiting for the database to become available
echo   Go get a coffee. Multi-AZ provisioning is genuinely slow.
aws rds wait db-instance-available --db-instance-identifier %DB_ID%
for /f "usebackq delims=" %%E in (`aws rds describe-db-instances --db-instance-identifier %DB_ID% --query "DBInstances[0].Endpoint.Address" --output text`) do set "DB_ENDPOINT=%%E"
call "%HERE%lib\save.bat" DB_ENDPOINT %DB_ENDPOINT%

echo.
echo   Deletion protection is ON. destroy-all.bat will ask before removing it.
echo.
echo Database ready. Next: 06-alb.bat
echo.
exit /b 0
