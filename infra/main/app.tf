# vote and result behind the load balancer: one Auto Scaling group each, of
# private instances in both app subnets, launched from the image infra/image
# bakes (Docker with awslogs, the CloudWatch agent, the AWS CLI). User data only
# starts the one container.

data "aws_ami" "app" {
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "name"
    values = ["${var.name_prefix}app-*"]
  }
}

# Provider default tags do not reach resources an Auto Scaling group launches.
data "aws_default_tags" "this" {}

locals {
  # The postgres image creates a database named after its user.
  db_user = "postgres"
  db_name = "postgres"

  app_user_data = {
    vote = templatefile("${path.module}/templates/vote-user-data.sh.tftpl", {
      image      = "${var.dockerhub_user}/vote:latest"
      redis_host = aws_instance.this["backend"].private_ip
    })
    result = templatefile("${path.module}/templates/result-user-data.sh.tftpl", {
      image          = "${var.dockerhub_user}/result:latest"
      region         = var.region
      password_param = aws_ssm_parameter.db_password.name
      db_host        = aws_instance.this["db"].private_ip
      db_user        = local.db_user
      db_name        = local.db_name
    })
  }

  app_instance_profiles = {
    vote   = aws_iam_instance_profile.ec2.name
    result = aws_iam_instance_profile.result.name
  }
}

# result reads the database password at boot; vote does not, so it keeps the plain instance role.
resource "aws_iam_role" "result" {
  name               = "${var.name_prefix}result"
  assume_role_policy = aws_iam_role.ec2.assume_role_policy
}

resource "aws_iam_role_policy_attachment" "result_ec2" {
  role       = aws_iam_role.result.name
  policy_arn = aws_iam_policy.ec2.arn
}

# The aws/ssm key policy already lets principals in this account decrypt through
# SSM, so reading the SecureString needs no kms:Decrypt here.
data "aws_iam_policy_document" "result_password" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.db_password.arn]
  }
}

resource "aws_iam_role_policy" "result_password" {
  name   = "read-db-password"
  role   = aws_iam_role.result.id
  policy = data.aws_iam_policy_document.result_password.json
}

resource "aws_iam_instance_profile" "result" {
  name = "${var.name_prefix}result"
  role = aws_iam_role.result.name
}

resource "aws_launch_template" "app" {
  for_each = local.apps

  name                   = "${var.name_prefix}${each.key}"
  image_id               = data.aws_ami.app.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this[each.key].id]
  user_data              = base64encode(local.app_user_data[each.key])
  update_default_version = true

  iam_instance_profile {
    name = local.app_instance_profiles[each.key]
  }

  # Hop limit 1: only host processes use the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # AWS recommends detailed monitoring when scaling on EC2 metrics.
  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = data.aws_ami.app.root_device_name

    ebs {
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.value
      tags          = merge(data.aws_default_tags.this.tags, { Name = "${var.name_prefix}${each.key}" })
    }
  }

  tags = {
    Name = "${var.name_prefix}${each.key}"
  }
}

resource "aws_autoscaling_group" "app" {
  for_each = local.apps

  name     = "${var.name_prefix}${each.key}"
  min_size = 2
  max_size = 4
  # No desired_capacity: the scaling policy owns it. A fixed value would make
  # terraform plan show a change after every scale-out, and an apply undo it.

  vpc_zone_identifier       = [for subnet in aws_subnet.app : subnet.id]
  target_group_arns         = [aws_lb_target_group.app[each.key].arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.app[each.key].id
    version = aws_launch_template.app[each.key].latest_version
  }

  # Launch before terminate, for refreshes and health replacements alike.
  instance_maintenance_policy {
    min_healthy_percentage = 100
    max_healthy_percentage = 200
  }

  # No preferences block: it would send its own 90/100 percent and override
  # the maintenance policy above.
  instance_refresh {
    strategy = "Rolling"
  }

  dynamic "tag" {
    for_each = merge(data.aws_default_tags.this.tags, { Name = "${var.name_prefix}${each.key}" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # New instances pull their image through the NAT.
  depends_on = [aws_route_table_association.private]
}

# vote: one HTTP request per page view or vote, so request count tracks its load.
resource "aws_autoscaling_policy" "vote" {
  name                   = "${var.name_prefix}vote-requests"
  autoscaling_group_name = aws_autoscaling_group.app["vote"].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app["vote"].arn_suffix}"
    }

    target_value = 100
  }
}

# result: long-lived WebSockets plus one database poll per instance, so CPU, not request count.
resource "aws_autoscaling_policy" "result" {
  name                   = "${var.name_prefix}result-cpu"
  autoscaling_group_name = aws_autoscaling_group.app["result"].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50
  }
}
