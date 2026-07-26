@echo off
REM Finds resources that survive a teardown and quietly keep billing.
set "HERE=%~dp0"
call "%HERE%lib\init.bat" || exit /b 1

echo.
echo ==^> EC2 instances ^(any non-terminated state^)
aws ec2 describe-instances --filters "Name=tag:Project,Values=%PROJECT%" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType]" --output table

echo.
echo ==^> Unattached EBS volumes ^(~$0.08/GB-month, silent^)
aws ec2 describe-volumes --filters "Name=status,Values=available" --query "Volumes[].[VolumeId,Size,CreateTime]" --output table

echo.
echo ==^> EBS snapshots you own ^(~$0.05/GB-month^)
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[].[SnapshotId,VolumeSize,StartTime]" --output table

echo.
echo ==^> Unassociated Elastic IPs ^(~$3.60/month EACH^)
aws ec2 describe-addresses --query "Addresses[?AssociationId==null].[PublicIp,AllocationId]" --output table

echo.
echo ==^> NAT gateways ^(~$35/month EACH - the usual culprit^)
aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available" --query "NatGateways[].[NatGatewayId,State,VpcId]" --output table

echo.
echo ==^> Load balancers ^(~$20/month, runs happily with zero targets^)
aws elbv2 describe-load-balancers --query "LoadBalancers[].[LoadBalancerName,State.Code,Type]" --output table

echo.
echo ==^> Target groups
aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupName" --output table

echo.
echo ==^> RDS instances
aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,MultiAZ,DBInstanceClass]" --output table

echo.
echo ==^> Manual RDS snapshots ^(kept on purpose - ~$0.095/GB-month^)
aws rds describe-db-snapshots --snapshot-type manual --query "DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,SnapshotCreateTime]" --output table

echo.
echo ==^> Secrets, including those scheduled for deletion
aws secretsmanager list-secrets --include-planned-deletion --query "SecretList[].[Name,DeletedDate]" --output table

echo.
echo ==^> CloudWatch log groups ^(default retention: NEVER EXPIRE^)
aws logs describe-log-groups --log-group-name-prefix "/%PROJECT%" --query "logGroups[].[logGroupName,storedBytes,retentionInDays]" --output table

echo.
echo ==^> VPCs
aws ec2 describe-vpcs --query "Vpcs[].[VpcId,CidrBlock,IsDefault]" --output table

echo.
echo ==^> Launch templates
aws ec2 describe-launch-templates --query "LaunchTemplates[].[LaunchTemplateName,CreateTime]" --output table 2>nul

echo.
echo ==^> CATCH-ALL: anything still tagged Project=%PROJECT%
echo   If you tagged consistently, this finds everything in one shot.
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=%PROJECT%" --query "ResourceTagMappingList[].ResourceARN" --output text

echo.
echo Re-run this in 48 hours - AWS billing data lags by up to a day.
echo.
exit /b 0
