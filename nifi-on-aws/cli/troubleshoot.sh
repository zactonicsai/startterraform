#!/usr/bin/env bash
# ===========================================================================
# Collect everything you would otherwise gather by hand at 2am.
# ===========================================================================
source "$(dirname "$0")/lib/common.sh"

info "Recorded resources"
sed 's/^export /    /' "$IDS" | grep -v PASSWORD || true

info "Instance state"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PrivateIpAddress,Tags[?Key==`Name`]|[0].Value]' \
  --output table

if is_cluster && have TG_ARN; then
  info "Target health + WHY"
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' \
    --output table
  cat <<'TXT'
    Reading the Reason column:
      Target.ResponseCodeMismatch  NiFi answered, but not with 200-401.
                                   Usually nifi.web.proxy.host is missing the
                                   ALB name -> run ./06-nifi-nodes.sh --refresh-proxy
      Target.Timeout               NiFi is still starting, or the security group
                                   does not allow 8443 from the ALB group.
      Target.FailedHealthChecks    NiFi crashed. Read nifi-app.log.
      Elb.InitialHealthChecking    Just wait.
TXT
fi

info "Recent CloudWatch log streams"
if have LOG_GROUP; then
  aws logs describe-log-streams --log-group-name "$LOG_GROUP" \
    --order-by LastEventTime --descending --max-items 8 \
    --query 'logStreams[].[logStreamName,lastEventTimestamp]' --output table 2>/dev/null || warn "no streams yet"
  info "Last 25 errors from nifi-app across all nodes"
  aws logs filter-log-events --log-group-name "$LOG_GROUP" \
    --filter-pattern "ERROR" --max-items 25 \
    --query 'events[].message' --output text 2>/dev/null | cut -c1-200 || warn "none found"
fi

info "Per-node container state"
for i in $(seq 1 "$NODE_COUNT"); do
  eval "id=\${NIFI_INSTANCE_$i:-}"; [ -z "$id" ] && continue
  echo "  --- node $i ($id) ---"
  CMD=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters 'commands=["docker ps -a --format {{.Names}}\t{{.Status}}","df -h /data | tail -1","free -m | head -2","tail -5 /data/nifi/logs/nifi-app.log 2>/dev/null || echo no-app-log"]' \
    --query 'Command.CommandId' --output text 2>/dev/null) || { warn "SSM unavailable"; continue; }
  sleep 6
  aws ssm get-command-invocation --command-id "$CMD" --instance-id "$id" \
    --query 'StandardOutputContent' --output text 2>/dev/null | sed 's/^/      /' || warn "no output"
done

cat <<'TXT'

===========================================================================
  Most common NiFi-on-AWS failures, by symptom

  Blank page / "Invalid host header"
      nifi.web.proxy.host does not include the ALB DNS name.
      -> ./06-nifi-nodes.sh --refresh-proxy

  503 from the load balancer
      No healthy targets. Check target health Reason above.

  Nodes stuck at "Connecting" in the Cluster view
      Port 11443 blocked between nodes, or NIFI_CLUSTER_ADDRESS is not
      resolvable. Confirm VPC DNS hostnames are enabled.

  Node joins then is kicked out
      Sensitive props key differs between nodes, or clocks have drifted.

  Random logouts, half-drawn canvas
      Sticky sessions are off on the target group.

  Container restarts in a loop
      Almost always: admin password under 12 characters, or the data volume
      is not mounted so NiFi cannot write its repositories.

  "docker pull" failed in bootstrap
      NAT Gateway missing/unavailable, or Artifactory credentials wrong.
      Check /var/log/nifi-bootstrap.log on the node.
===========================================================================
TXT
