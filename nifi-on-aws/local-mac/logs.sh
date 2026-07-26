#!/usr/bin/env bash
# Follow the NiFi logs. There are four, and they answer different questions.
set -euo pipefail
WHICH="${1:-app}"
case "$WHICH" in
  app)   F=nifi-app.log ;;        # what your flow is doing, plus errors
  user)  F=nifi-user.log ;;       # who logged in, who was denied
  boot)  F=nifi-bootstrap.log ;;  # startup and JVM problems
  req)   F=nifi-request.log ;;    # every HTTP request to the API
  dep)   F=nifi-deprecation.log ;; # components that will break on upgrade
  *) echo "usage: $0 [app|user|boot|req|dep]"; exit 1 ;;
esac
echo "==> tailing $F  (Ctrl-C to stop)"
docker exec -it nifi tail -f "/opt/nifi/nifi-current/logs/$F" 2>/dev/null \
  || tail -f "data/logs/$F"
