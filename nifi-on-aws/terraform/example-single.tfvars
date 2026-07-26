# The cheapest thing that works. Roughly $75-95/month.
# No load balancer, no ZooKeeper. Reach it via SSM port forwarding.
project            = "nifi-lab"
node_count         = 1
nifi_instance_type = "t3.large"
data_volume_gb     = 50
allowed_cidr       = "203.0.113.10/32"
artifactory_registry = "mycompany.jfrog.io"
nifi_version       = "2.10.0"
log_retention_days = 7
