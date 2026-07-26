@echo off
REM Renders user-data, then creates (or versions) the launch template.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1
if "%DB_ENDPOINT%"=="" ( echo [FAIL] Run 05-rds.bat first. & exit /b 1 )
if "%ROLE_NAME%"=="" ( echo [FAIL] Run 04-iam.bat first. & exit /b 1 )

set "LOG_GROUP=/%PROJECT%/keycloak"
call "%HERE%lib\save.bat" LOG_GROUP %LOG_GROUP%

echo.
echo ==^> Creating the CloudWatch log group
aws logs create-log-group --log-group-name "%LOG_GROUP%" --tags "Project=%PROJECT%" >nul 2>nul
if errorlevel 1 ( echo   [warn] Log group already exists ) else ( echo   [ok] Log group created )
aws logs put-retention-policy --log-group-name "%LOG_GROUP%" --retention-in-days 14
echo   [ok] Retention 14 days ^(logs default to never expiring - that costs money^)

echo.
echo ==^> Rendering user-data from templates\user-data.sh.tmpl
echo   render.ps1 also forces LF line endings. CRLF user-data fails on Linux.
set "GEN=%HERE%state\user-data-generated.sh"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%lib\render.ps1" -In "%TEMPLATE_DIR%\user-data.sh.tmpl" -Out "%GEN%"
if errorlevel 1 ( echo [FAIL] user-data rendering failed & exit /b 1 )

echo.
echo ==^> Finding the latest Amazon Linux 2023 AMI
for /f "usebackq delims=" %%A in (`aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameter.Value" --output text`) do set "AMI_ID=%%A"
call "%HERE%lib\save.bat" AMI_ID %AMI_ID%

echo.
echo ==^> Building the launch-template JSON ^(base64 user-data embedded^)
set "LTJSON=%HERE%state\lt.json"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%lib\render.ps1" -In "%HERE%lib\lt-template.json" -Out "%LTJSON%" -Base64From "%GEN%"
if errorlevel 1 ( echo [FAIL] launch template JSON build failed & exit /b 1 )

if not "%LT_ID%"=="" (
  echo.
  echo ==^> Launch template exists - creating a NEW VERSION instead
  for /f "usebackq delims=" %%V in (`aws ec2 create-launch-template-version --launch-template-id %LT_ID% --version-description "updated" --launch-template-data file://"%LTJSON%" --query "LaunchTemplateVersion.VersionNumber" --output text`) do set "LTVER=%%V"
  echo   [ok] Created version %LTVER%
  echo   Roll it out with:
  echo     aws autoscaling start-instance-refresh --auto-scaling-group-name %PROJECT%-asg
) else (
  echo.
  echo ==^> Creating the launch template
  for /f "usebackq delims=" %%L in (`aws ec2 create-launch-template --launch-template-name %PROJECT%-lt --version-description "v1 initial" --launch-template-data file://"%LTJSON%" --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=%PROJECT%}]" --query "LaunchTemplate.LaunchTemplateId" --output text`) do set "LT_ID=%%L"
  if "%LT_ID%"=="" ( echo [FAIL] launch template creation failed & exit /b 1 )
  call "%HERE%lib\save.bat" LT_ID %LT_ID%
)

echo.
echo   IMDSv2 is required on this template - protects IAM creds from SSRF.
echo.
echo Launch template ready. Next: 08-asg.bat
echo.
exit /b 0
