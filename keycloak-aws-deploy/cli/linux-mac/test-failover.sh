#!/usr/bin/env bash
# Chaos tests. Untested fault tolerance is just a hope.
# Usage: ./test-failover.sh [kill-instance|kill-container|db-failover|load|watch]
. "$(dirname "$0")/lib/common.sh"
load_config; require_state ASG_NAME TG_ARN

CMD="${1:-watch}"

traffic_hint() {
  cat << TXT

  ${C_BOLD}Run this in a SECOND terminal first${C_RESET}, so you can see the user impact:

    while true; do curl -s -o /dev/null -w "%{http_code} " \\
      https://${DOMAIN_NAME}/realms/master; sleep 1; done

  You want an unbroken stream of 200s throughout the test.

TXT
}

case "$CMD" in
  kill-instance)
    traffic_hint
    confirm "Terminate one instance? Type yes:"
    V=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
    step "Terminating $V"
    aws ec2 terminate-instances --instance-ids "$V" >/dev/null
    ok "Terminated. Expected: no user-visible errors; replacement healthy in 3-5 min."
    info "If you DO see errors: ASG_MIN was 1, or both instances were in one AZ."
    exec "$0" watch
    ;;
  kill-container)
    traffic_hint
    info "This breaks the APP but leaves the VM healthy. It proves your ASG"
    info "health-check-type is ELB and not EC2 - an EC2 check cannot see this."
    ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
    confirm "Stop the Keycloak container on $ID? Type yes:"
    aws ssm send-command --instance-ids "$ID" \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["docker stop keycloak"]' \
      --query 'Command.CommandId' --output text
    ok "Command sent. Expected: unhealthy in ~45s (3 x 15s), replaced a few min later."
    exec "$0" watch
    ;;
  db-failover)
    traffic_hint
    warn "Expect 60-120s of database errors. This is the real test of Multi-AZ."
    confirm "Force an RDS failover? Type yes:"
    aws rds reboot-db-instance --db-instance-identifier "$DB_ID" --force-failover >/dev/null
    ok "Failover triggered."
    info "Watch for it in the events:"
    sleep 30
    aws rds describe-events --source-identifier "$DB_ID" --source-type db-instance \
      --duration 20 --query 'Events[].[Date,Message]' --output table
    info "Afterwards, check whether instances RECOVERED or were all REPLACED."
    info "Fleet-wide replacement after a 90s blip = your unhealthy threshold is too"
    info "aggressive, and a brief degradation became a full outage."
    ;;
  load)
    cat << TXT

  Install a load generator outside the VPC, then:

    hey -z 5m -c 200 https://${DOMAIN_NAME}/realms/master/.well-known/openid-configuration

  ${C_YEL}Important:${C_RESET} that endpoint is cached and cheap. For a realistic test,
  drive the actual login flow - password hashing (Argon2/PBKDF2) is the
  expensive part and is what really consumes CPU.

TXT
    exec "$0" watch
    ;;
  watch)
    step "Watching target health - Ctrl-C to stop"
    while true; do
      clear
      printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "target group health"
      aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
        --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
        --output table 2>/dev/null
      aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Count:length(Instances)}' \
        --output table 2>/dev/null
      sleep 15
    done
    ;;
  *)
    echo "Usage: $0 [kill-instance|kill-container|db-failover|load|watch]"; exit 1 ;;
esac
