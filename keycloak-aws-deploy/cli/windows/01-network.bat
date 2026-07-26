@echo off
REM Creates the VPC, 6 subnets across 2 AZs, IGW, NAT gateways and route tables.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

call "%HERE%lib\save.bat" AZ_A %AWS_REGION%a
call "%HERE%lib\save.bat" AZ_B %AWS_REGION%b

REM ---------- VPC ----------
if not "%VPC_ID%"=="" (
  echo   [warn] VPC already recorded ^(%VPC_ID%^) - skipping
) else (
  echo.
  echo ==^> Creating VPC 10.0.0.0/16
  for /f "usebackq delims=" %%I in (`aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=%PROJECT%-vpc},{Key=Project,Value=%PROJECT%}]" --query "Vpc.VpcId" --output text`) do set "VPC_ID=%%I"
  if "%VPC_ID%"=="" ( echo [FAIL] VPC creation failed & exit /b 1 )
  call "%HERE%lib\save.bat" VPC_ID %VPC_ID%
  REM DNS hostnames are REQUIRED for the RDS endpoint to resolve inside the VPC
  aws ec2 modify-vpc-attribute --vpc-id %VPC_ID% --enable-dns-support
  aws ec2 modify-vpc-attribute --vpc-id %VPC_ID% --enable-dns-hostnames
  echo   [ok] DNS support and hostnames enabled
)

REM ---------- subnets ----------
echo.
echo ==^> Creating subnets ^(public / app / data, 2 AZs each^)
call :mksubnet PUB_A 10.0.1.0/24  %AZ_A% public-a public yes
call :mksubnet PUB_B 10.0.2.0/24  %AZ_B% public-b public yes
call :mksubnet APP_A 10.0.11.0/24 %AZ_A% app-a    app    no
call :mksubnet APP_B 10.0.12.0/24 %AZ_B% app-b    app    no
call :mksubnet DB_A  10.0.21.0/24 %AZ_A% db-a     data   no
call :mksubnet DB_B  10.0.22.0/24 %AZ_B% db-b     data   no

REM ---------- internet gateway ----------
if not "%IGW_ID%"=="" (
  echo   [warn] IGW already recorded - skipping
) else (
  echo.
  echo ==^> Creating and attaching the internet gateway
  for /f "usebackq delims=" %%I in (`aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=%PROJECT%-igw},{Key=Project,Value=%PROJECT%}]" --query "InternetGateway.InternetGatewayId" --output text`) do set "IGW_ID=%%I"
  call "%HERE%lib\save.bat" IGW_ID %IGW_ID%
  aws ec2 attach-internet-gateway --vpc-id %VPC_ID% --internet-gateway-id %IGW_ID%
)

REM ---------- public route table ----------
if not "%RTB_PUB%"=="" (
  echo   [warn] Public route table already recorded - skipping
) else (
  echo.
  echo ==^> Creating the public route table
  for /f "usebackq delims=" %%I in (`aws ec2 create-route-table --vpc-id %VPC_ID% --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=%PROJECT%-rtb-public},{Key=Project,Value=%PROJECT%}]" --query "RouteTable.RouteTableId" --output text`) do set "RTB_PUB=%%I"
  call "%HERE%lib\save.bat" RTB_PUB %RTB_PUB%
  aws ec2 create-route --route-table-id %RTB_PUB% --destination-cidr-block 0.0.0.0/0 --gateway-id %IGW_ID% >nul
  aws ec2 associate-route-table --route-table-id %RTB_PUB% --subnet-id %PUB_A% >nul
  aws ec2 associate-route-table --route-table-id %RTB_PUB% --subnet-id %PUB_B% >nul
  echo   [ok] Default route to IGW, both public subnets associated
)

REM ---------- NAT gateway A ----------
if not "%NAT_A%"=="" (
  echo   [warn] NAT gateway A already recorded - skipping
) else (
  echo.
  echo ==^> Allocating Elastic IP + NAT gateway in AZ A
  for /f "usebackq delims=" %%I in (`aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=%PROJECT%-eip-a},{Key=Project,Value=%PROJECT%}]" --query "AllocationId" --output text`) do set "EIP_A=%%I"
  call "%HERE%lib\save.bat" EIP_A %EIP_A%
  for /f "usebackq delims=" %%I in (`aws ec2 create-nat-gateway --subnet-id %PUB_A% --allocation-id %EIP_A% --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=%PROJECT%-nat-a},{Key=Project,Value=%PROJECT%}]" --query "NatGateway.NatGatewayId" --output text`) do set "NAT_A=%%I"
  call "%HERE%lib\save.bat" NAT_A %NAT_A%
)

REM ---------- NAT gateway B ----------
if /i "%SINGLE_NAT%"=="true" (
  echo   SINGLE_NAT=true - both AZs share NAT gateway A ^(cheaper, less resilient^)
  call "%HERE%lib\save.bat" NAT_B %NAT_A%
) else (
  if not "%NAT_B%"=="" (
    echo   [warn] NAT gateway B already recorded - skipping
  ) else (
    echo.
    echo ==^> Allocating Elastic IP + NAT gateway in AZ B
    for /f "usebackq delims=" %%I in (`aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=%PROJECT%-eip-b},{Key=Project,Value=%PROJECT%}]" --query "AllocationId" --output text`) do set "EIP_B=%%I"
    call "%HERE%lib\save.bat" EIP_B %EIP_B%
    for /f "usebackq delims=" %%I in (`aws ec2 create-nat-gateway --subnet-id %PUB_B% --allocation-id %EIP_B% --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=%PROJECT%-nat-b},{Key=Project,Value=%PROJECT%}]" --query "NatGateway.NatGatewayId" --output text`) do set "NAT_B=%%I"
    call "%HERE%lib\save.bat" NAT_B %NAT_B%
  )
)

echo.
echo ==^> Waiting for NAT gateway^(s^) to become available ^(2-5 minutes^)
if "%NAT_A%"=="%NAT_B%" (
  aws ec2 wait nat-gateway-available --nat-gateway-ids %NAT_A%
) else (
  aws ec2 wait nat-gateway-available --nat-gateway-ids %NAT_A% %NAT_B%
)
echo   [ok] NAT gateway^(s^) ready

echo.
echo ==^> Creating private route tables ^(one per AZ^)
call :mkprivrtb RTB_A rtb-private-a %NAT_A% %APP_A% %DB_A%
call :mkprivrtb RTB_B rtb-private-b %NAT_B% %APP_B% %DB_B%

echo.
echo Network ready. Next: 02-security-groups.bat
echo.
exit /b 0

REM ============================ subroutines ============================
:mksubnet
REM %1=VAR %2=CIDR %3=AZ %4=NAME %5=TIER %6=PUBLIC
call set "_EXIST=%%%~1%%"
if not "%_EXIST%"=="" ( echo   [warn] %~1 exists - skipping & exit /b 0 )
for /f "usebackq delims=" %%I in (`aws ec2 create-subnet --vpc-id %VPC_ID% --cidr-block %~2 --availability-zone %~3 --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=%PROJECT%-%~4},{Key=Tier,Value=%~5},{Key=Project,Value=%PROJECT%}]" --query "Subnet.SubnetId" --output text`) do set "_SID=%%I"
if "%_SID%"=="" ( echo [FAIL] subnet %~4 creation failed & exit /b 1 )
if /i "%~6"=="yes" aws ec2 modify-subnet-attribute --subnet-id %_SID% --map-public-ip-on-launch
call "%HERE%lib\save.bat" %~1 %_SID%
set "_SID="
exit /b 0

:mkprivrtb
REM %1=VAR %2=NAME %3=NATID %4=SUBNET1 %5=SUBNET2
call set "_EXIST=%%%~1%%"
if not "%_EXIST%"=="" ( echo   [warn] %~1 exists - skipping & exit /b 0 )
for /f "usebackq delims=" %%I in (`aws ec2 create-route-table --vpc-id %VPC_ID% --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=%PROJECT%-%~2},{Key=Project,Value=%PROJECT%}]" --query "RouteTable.RouteTableId" --output text`) do set "_RID=%%I"
call "%HERE%lib\save.bat" %~1 %_RID%
aws ec2 create-route --route-table-id %_RID% --destination-cidr-block 0.0.0.0/0 --nat-gateway-id %~3 >nul
aws ec2 associate-route-table --route-table-id %_RID% --subnet-id %~4 >nul
aws ec2 associate-route-table --route-table-id %_RID% --subnet-id %~5 >nul
set "_RID="
exit /b 0
