# The public entry point: an Application Load Balancer in both public subnets.
# HTTPS on <app_hostname>.<domain_zone> with an ACM certificate; HTTP redirects
# to HTTPS. vote is the default target and result serves /result.

data "aws_route53_zone" "this" {
  name         = var.domain_zone
  private_zone = false
}

locals {
  app_fqdn = "${var.app_hostname}.${var.domain_zone}"
  apps     = toset(["vote", "result"])
}

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_91:access logs need an S3 bucket that would outlive this course stack
  #checkov:skip=CKV_AWS_150:the stack is torn down after the course; deletion protection would only block that
  #checkov:skip=CKV2_AWS_28:a paid web ACL is out of proportion for a vote demo

  name                       = "${var.name_prefix}alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.this["alb"].id]
  subnets                    = [aws_subnet.public.id, aws_subnet.public_b.id]
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.name_prefix}alb"
  }
}

resource "aws_lb_target_group" "app" {
  for_each = local.apps

  #checkov:skip=CKV_AWS_378:TLS ends at the load balancer; the targets serve plain HTTP inside the VPC

  name                 = "${var.name_prefix}${each.key}"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  # GET / touches neither Redis (vote) nor Postgres (result), so a data-tier
  # outage does not mark every web instance unhealthy and drain the group.
  health_check {
    path    = "/"
    matcher = "200"
  }

  # A WebSocket stays on its target once upgraded; the cookie keeps result's
  # fall back to HTTP long-polling on one target too, which Socket.IO needs.
  stickiness {
    type    = "lb_cookie"
    enabled = each.key == "result"
  }

  tags = {
    Name = "${var.name_prefix}${each.key}"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # The port must be set: the redirect would otherwise keep the incoming port 80.
  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  # AWS's recommended policy; the provider default is the legacy ELBSecurityPolicy-2016-08.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  routing_http_response_strict_transport_security_header_value = "max-age=31536000"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["vote"].arn
  }
}

# result serves its page, assets and Socket.IO under /result/.
resource "aws_lb_listener_rule" "result" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["result"].arn
  }

  condition {
    path_pattern {
      values = ["/result", "/result/*"]
    }
  }
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.app_fqdn
  validation_method = "DNS"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  tags = {
    Name = "${var.name_prefix}app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# The HTTPS listener takes the certificate from here, so it waits for issuance.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
