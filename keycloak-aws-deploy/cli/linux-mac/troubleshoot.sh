#!/usr/bin/env bash
# Diagnostic helper.  Usage: ./troubleshoot.sh [logs|shell|health|events|freeze|thaw]
. "$(dirname "$0")/lib/common.sh"
load_config; load_state
CMD="${1:-health}"

first_instance() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text
}

case "$CMD" in
  health)
    step "Target health"
    aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].{T:Target.Id,S:TargetHealth.State,R:TargetHealth.Reason,D:TargetHealth.Description}' \
      --output table
    step "RDS status"
    aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
      --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,Endpoint:Endpoint.Address}' \
      --output table
    ;;
  logs)
    step "Last 100 CloudWatch log lines from $LOG_GROUP"
    STREAM=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" \
      --order-by LastEventTime --descending --max-items 1 \
      --query 'logStreams[0].logStreamName' --output text)
    [ "$STREAM" = "None" ] && die "No log streams yet. The container may not have started."
    info "Stream: $STREAM"
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" \
      --limit 100 --query 'events[].message' --output text
    ;;
  shell)
    ID=$(first_instance)
    step "Opening an SSM session to $ID"
    info "Useful commands once inside:"
    info "  sudo tail -100 /var/log/keycloak-bootstrap.log"
    info "  sudo docker ps -a"
    info "  sudo docker logs keycloak --tail 100"
    info "  curl -s localhost:9000/health/ready"
    info "  sudo docker logs keycloak 2>&1 | grep -i -E 'ISPN|cluster|view'"
    aws ssm start-session --target "$ID"
    ;;
  events)
    step "Recent ASG activity"
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG_NAME" \
      --max-records 15 --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:Description}' --output table
    step "Recent RDS events"
    aws rds describe-events --source-identifier "$DB_ID" --source-type db-instance \
      --duration 1440 --query 'Events[].[Date,Message]' --output table
    ;;
  freeze)
    step "Suspending ReplaceUnhealthy + Terminate"
    aws autoscaling suspend-processes --auto-scaling-group-name "$ASG_NAME" \
      --scaling-processes ReplaceUnhealthy Terminate
    ok "The ASG will now leave broken instances alone so you can investigate."
    warn "Remember to run: ./troubleshoot.sh thaw"
    ;;
  thaw)
    step "Resuming all ASG processes"
    aws autoscaling resume-processes --auto-scaling-group-name "$ASG_NAME"
    ok "Self-healing re-enabled."
    ;;
  *)
    echo "Usage: $0 [health|logs|shell|events|freeze|thaw]"; exit 1 ;;
esac
