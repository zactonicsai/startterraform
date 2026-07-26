@echo off
REM Verifies tools, credentials and config BEFORE anything is created.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

echo.
echo ==^> Checking required commands
where aws >nul 2>nul || ( echo [FAIL] aws CLI not found in PATH & exit /b 1 )
echo   [ok] aws found
where powershell >nul 2>nul || ( echo [FAIL] powershell not found & exit /b 1 )
echo   [ok] powershell found

echo.
echo ==^> AWS CLI version
aws --version

echo.
echo ==^> Checking AWS credentials
for /f "usebackq delims=" %%A in (`aws sts get-caller-identity --query "Account" --output text`) do set "ACCOUNT=%%A"
if "%ACCOUNT%"=="" ( echo [FAIL] Cannot authenticate to AWS. & exit /b 1 )
echo   Account : %ACCOUNT%
echo   Region  : %AWS_REGION%
echo   [ok] Credentials valid

echo.
call "%HERE%lib\confirm.bat" "Deploy '%PROJECT%' into account %ACCOUNT% / %AWS_REGION% ? Type yes:" yes || exit /b 1

echo.
echo ==^> Validating config values
echo %ACM_CERT_ARN% | findstr /c:"REPLACE-ME" >nul && ( echo [FAIL] ACM_CERT_ARN still contains REPLACE-ME & exit /b 1 )
echo %ARTIFACTORY_TOKEN% | findstr /c:"REPLACE-ME" >nul && ( echo [FAIL] ARTIFACTORY_TOKEN not set & exit /b 1 )
echo %KC_IMAGE% | findstr /c:":latest" >nul && ( echo [FAIL] KC_IMAGE uses :latest - pin an explicit version tag & exit /b 1 )
echo %KC_IMAGE% | findstr /c:":" >nul || ( echo [FAIL] KC_IMAGE has no tag - pin an explicit version & exit /b 1 )
echo   [ok] Config looks sane

echo.
echo ==^> Verifying the ACM certificate exists in %AWS_REGION%
aws acm describe-certificate --certificate-arn "%ACM_CERT_ARN%" --query "Certificate.[DomainName,Status]" --output text
if errorlevel 1 (
  echo [FAIL] Certificate not found in %AWS_REGION%.
  echo        An ALB certificate must be in the SAME region as the ALB.
  exit /b 1
)

echo.
echo ==^> Checking service permissions
aws ec2 describe-vpcs --max-items 1 >nul || ( echo [FAIL] No EC2 read permission & exit /b 1 )
aws rds describe-db-instances --max-items 1 >nul || ( echo [FAIL] No RDS read permission & exit /b 1 )
aws elbv2 describe-load-balancers --max-items 1 >nul || ( echo [FAIL] No ELB read permission & exit /b 1 )
aws secretsmanager list-secrets --max-results 1 >nul || ( echo [FAIL] No Secrets Manager permission & exit /b 1 )
echo   [ok] Permissions look sufficient

echo.
echo Preflight passed. Next: 01-network.bat
echo.
exit /b 0
