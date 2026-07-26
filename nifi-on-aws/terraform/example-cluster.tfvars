# Three nodes across two AZs, ALB, ZooKeeper. Roughly $290-400/month.
project             = "nifi-prod"
node_count          = 3
nifi_instance_type  = "m6i.large"
data_volume_gb      = 200
allowed_cidr        = "198.51.100.0/24"
artifactory_registry = "mycompany.jfrog.io"
nifi_version        = "2.10.0"
acm_certificate_arn = "arn:aws:acm:eu-west-1:111122223333:certificate/REPLACE-ME"
hosted_zone_id      = "Z0123456789ABCDEFGHIJ"
nifi_hostname       = "nifi.example.com"
log_retention_days  = 90
