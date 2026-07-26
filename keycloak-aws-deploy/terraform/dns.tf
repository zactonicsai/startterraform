data "aws_route53_zone" "main" {
  count = var.route53_zone_name != "" ? 1 : 0
  name  = var.route53_zone_name
}

# An ALIAS record, not a CNAME. An ALB's IPs change over time so an A record
# with a fixed IP is impossible; a CNAME cannot be used at the zone apex and
# adds a lookup. ALIAS resolves to the ALB's current IPs, is free to query,
# and works at the apex.
resource "aws_route53_record" "keycloak" {
  count = var.route53_zone_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
