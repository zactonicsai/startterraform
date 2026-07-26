@echo off
REM Builds the optimized Keycloak image and pushes it to Artifactory.
REM Usage: build-and-push.bat [keycloak-version]
setlocal

set "HERE=%~dp0"
if exist "%HERE%..\cli\windows\config.bat" call "%HERE%..\cli\windows\config.bat"

set "KC_VERSION=%~1"
if "%KC_VERSION%"=="" set "KC_VERSION=26.4.0"
if "%ARTIFACTORY_REPO%"=="" set "ARTIFACTORY_REPO=docker-local"

if "%ARTIFACTORY_HOST%"=="" ( echo [FAIL] ARTIFACTORY_HOST not set & exit /b 1 )
if "%ARTIFACTORY_TOKEN%"=="" ( echo [FAIL] ARTIFACTORY_TOKEN not set & exit /b 1 )

set "TAG=%ARTIFACTORY_HOST%/%ARTIFACTORY_REPO%/keycloak:%KC_VERSION%-optimized"

echo ==^> Building %TAG%
docker build --build-arg KEYCLOAK_VERSION=%KC_VERSION% -t "%TAG%" "%HERE%"
if errorlevel 1 ( echo [FAIL] build failed & exit /b 1 )

echo ==^> Logging in to %ARTIFACTORY_HOST%
echo %ARTIFACTORY_TOKEN% | docker login %ARTIFACTORY_HOST% --username %ARTIFACTORY_USER% --password-stdin
if errorlevel 1 ( echo [FAIL] login failed & exit /b 1 )

echo ==^> Pushing
docker push "%TAG%"

echo ==^> Cleaning up local credentials
docker logout %ARTIFACTORY_HOST%

echo.
echo Done. Now set this in your config:
echo   cli\windows\config.bat    set KC_IMAGE=%TAG%
echo   terraform.tfvars          keycloak_image = "%TAG%"
echo.
exit /b 0
