@echo off
REM Creates the least-privilege EC2 role + instance profile.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%DB_SECRET_ARN%"=="" ( echo [FAIL] Run 03-secrets.bat first. & exit /b 1 )

set "ROLE_NAME=%PROJECT%-ec2-role"
call "%HERE%lib\save.bat" ROLE_NAME %ROLE_NAME%
set "TMPD=%HERE%state"

echo.
echo ==^> Creating the IAM role
> "%TMPD%\trust.json" echo {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
aws iam get-role --role-name %ROLE_NAME% >nul 2>nul
if errorlevel 1 (
  aws iam create-role --role-name %ROLE_NAME% --assume-role-policy-document file://"%TMPD%\trust.json" --tags "Key=Project,Value=%PROJECT%" >nul
  echo   [ok] Role created
) else (
  echo   [warn] Role %ROLE_NAME% already exists - skipping
)

echo.
echo ==^> Attaching AWS managed policies
aws iam attach-role-policy --role-name %ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore && echo   [ok] AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name %ROLE_NAME% --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy && echo   [ok] CloudWatchAgentServerPolicy

echo.
echo ==^> Attaching a least-privilege inline policy for exactly 3 secrets
> "%TMPD%\secrets.json" echo {"Version":"2012-10-17","Statement":[{"Sid":"ReadOnlyTheseThreeSecrets","Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":["%DB_SECRET_ARN%","%ART_SECRET_ARN%","%KC_SECRET_ARN%"]}]}
aws iam put-role-policy --role-name %ROLE_NAME% --policy-name %PROJECT%-read-secrets --policy-document file://"%TMPD%\secrets.json"
echo   [ok] Named ARNs only - never Resource: *

echo.
echo ==^> Creating the instance profile
aws iam get-instance-profile --instance-profile-name %ROLE_NAME% >nul 2>nul
if errorlevel 1 (
  aws iam create-instance-profile --instance-profile-name %ROLE_NAME% --tags "Key=Project,Value=%PROJECT%" >nul
  aws iam add-role-to-instance-profile --instance-profile-name %ROLE_NAME% --role-name %ROLE_NAME%
  echo   [ok] Profile created and role attached
) else (
  echo   [warn] Instance profile already exists
)

del /q "%TMPD%\trust.json" "%TMPD%\secrets.json" 2>nul

echo.
echo ==^> Waiting 15s for IAM to propagate globally
timeout /t 15 /nobreak >nul
echo.
echo IAM ready. Next: 05-rds.bat
echo.
exit /b 0
