@echo off
REM Generates random passwords and stores all three secrets in Secrets Manager.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

echo.
echo ==^> Generating strong random passwords
REM PowerShell instead of openssl - 24 alphanumeric characters
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "-join ((48..57)+(65..90)+(97..122) ^| Get-Random -Count 24 ^| %%{[char]$_})"`) do set "DB_PASSWORD=%%P"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "-join ((48..57)+(65..90)+(97..122) ^| Get-Random -Count 24 ^| %%{[char]$_})"`) do set "KC_ADMIN_PASSWORD=%%P"
if "%DB_PASSWORD%"=="" ( echo [FAIL] password generation failed & exit /b 1 )
echo   [ok] Generated - they go straight into Secrets Manager, never into a file

REM A timestamp suffix avoids clashing with a secret still in its deletion window
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "[int][double]::Parse((Get-Date -UFormat %%s))"`) do set "STAMP=%%T"

echo.
echo ==^> Storing database credentials
if not "%DB_SECRET_ARN%"=="" (
  echo   [warn] DB_SECRET_ARN exists - skipping
) else (
  > "%HERE%state\db.json" echo {"username":"kcadmin","password":"%DB_PASSWORD%","engine":"postgres","port":5432,"dbname":"keycloak"}
  for /f "usebackq delims=" %%A in (`aws secretsmanager create-secret --name "%PROJECT%/db-credentials-%STAMP%" --description "Keycloak RDS master credentials" --secret-string file://"%HERE%state\db.json" --tags "Key=Project,Value=%PROJECT%" --query "ARN" --output text`) do set "DB_SECRET_ARN=%%A"
  del /q "%HERE%state\db.json"
  if "%DB_SECRET_ARN%"=="" ( echo [FAIL] could not create the DB secret & exit /b 1 )
  call "%HERE%lib\save.bat" DB_SECRET_ARN %DB_SECRET_ARN%
)

echo.
echo ==^> Storing Artifactory pull credentials
if not "%ART_SECRET_ARN%"=="" (
  echo   [warn] ART_SECRET_ARN exists - skipping
) else (
  > "%HERE%state\art.json" echo {"username":"%ARTIFACTORY_USER%","token":"%ARTIFACTORY_TOKEN%"}
  for /f "usebackq delims=" %%A in (`aws secretsmanager create-secret --name "%PROJECT%/artifactory-credentials-%STAMP%" --description "JFrog Artifactory pull credentials" --secret-string file://"%HERE%state\art.json" --tags "Key=Project,Value=%PROJECT%" --query "ARN" --output text`) do set "ART_SECRET_ARN=%%A"
  del /q "%HERE%state\art.json"
  call "%HERE%lib\save.bat" ART_SECRET_ARN %ART_SECRET_ARN%
)

echo.
echo ==^> Storing the TEMPORARY Keycloak bootstrap admin
if not "%KC_SECRET_ARN%"=="" (
  echo   [warn] KC_SECRET_ARN exists - skipping
) else (
  > "%HERE%state\kc.json" echo {"username":"tmpadmin","password":"%KC_ADMIN_PASSWORD%"}
  for /f "usebackq delims=" %%A in (`aws secretsmanager create-secret --name "%PROJECT%/keycloak-bootstrap-admin-%STAMP%" --description "TEMPORARY bootstrap admin - delete the user after first login" --secret-string file://"%HERE%state\kc.json" --tags "Key=Project,Value=%PROJECT%" --query "ARN" --output text`) do set "KC_SECRET_ARN=%%A"
  del /q "%HERE%state\kc.json"
  call "%HERE%lib\save.bat" KC_SECRET_ARN %KC_SECRET_ARN%
)

echo.
echo   Retrieve credentials later with:
echo     aws secretsmanager get-secret-value --secret-id "%DB_SECRET_ARN%" --query SecretString --output text
echo.
echo   The bootstrap admin is single-use. After your first login:
echo     1. create a real named admin account with MFA
echo     2. delete the 'tmpadmin' user
echo     3. delete the bootstrap secret
echo.
echo Secrets ready. Next: 04-iam.bat
echo.
exit /b 0
