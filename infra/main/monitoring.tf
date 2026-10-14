# CloudWatch: an instance role for the agent and the awslogs driver, log groups,
# a flow log of rejected traffic, and alarms that email the owner through SNS.

data "aws_caller_identity" "current" {}

locals {
  log_groups = toset(["containers", "ssh", "vpc-flow"])

  # Every host but the bastion runs containers and gets the four host alarms.
  alarm_hosts = setsubtract(toset(keys(local.instances)), ["bastion"])

  # The agent's StatsD input adds the dimension metric_type = gauge to every gauge.
  host_alarm_kinds = {
    cpu = {
      namespace  = "AWS/EC2"
      metric     = "CPUUtilization"
      statistic  = "Average"
      period     = 300
      periods    = 2
      comparison = "GreaterThanThreshold"
      threshold  = 80
      missing    = "missing"
      gauge      = false
      desc       = "CPU above 80 percent for 10 minutes"
    }
    memory = {
      namespace  = "CWAgent"
      metric     = "mem_used_percent"
      statistic  = "Average"
      period     = 300
      periods    = 2
      comparison = "GreaterThanThreshold"
      threshold  = 90
      missing    = "missing"
      gauge      = false
      desc       = "memory above 90 percent for 10 minutes"
    }
    containers-down = {
      namespace  = "CWAgent"
      metric     = "containers_down"
      statistic  = "Maximum"
      period     = 60
      periods    = 2
      comparison = "GreaterThanThreshold"
      threshold  = 0
      missing    = "breaching"
      gauge      = true
      desc       = "a container is not running or unhealthy, or the host stopped reporting"
    }
    container-restarts = {
      namespace  = "CWAgent"
      metric     = "container_restarts"
      statistic  = "Sum"
      period     = 300
      periods    = 1
      comparison = "GreaterThanThreshold"
      threshold  = 0
      missing    = "notBreaching"
      gauge      = true
      desc       = "a container restarted in the last 5 minutes"
    }
  }

  host_alarms = merge([
    for host in local.alarm_hosts : {
      for kind, alarm in local.host_alarm_kinds : "${host}-${kind}" => merge(alarm, { host = host })
    }
  ]...)

  alarms = merge(
    local.host_alarms,
    {
      # The bastion runs no containers: its memory metric doubles as a heartbeat,
      # in alarm only when it stops arriving.
      bastion-heartbeat = {
        host       = "bastion"
        namespace  = "CWAgent"
        metric     = "mem_used_percent"
        statistic  = "SampleCount"
        period     = 60
        periods    = 3
        comparison = "LessThanThreshold"
        threshold  = 1
        missing    = "breaching"
        gauge      = false
        desc       = "the bastion or its agent stopped reporting"
      }
    },
  )
}

# Instance role for the CloudWatch agent and Docker's awslogs driver, scoped to
# this stack's log groups and the CWAgent namespace (the account is shared).
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2" {
  statement {
    sid     = "WriteOwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = flatten([
      for group in ["containers", "ssh"] : [
        aws_cloudwatch_log_group.this[group].arn,
        "${aws_cloudwatch_log_group.this[group].arn}:*",
      ]
    ])
  }

  statement {
    sid       = "PutAgentMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CWAgent"]
    }
  }

  # Neither action supports resource-level permissions.
  statement {
    sid       = "ReadInstanceTagsAndVolumes"
    actions   = ["ec2:DescribeTags", "ec2:DescribeVolumes"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_policy" "ec2" {
  name        = "${var.name_prefix}ec2"
  description = "CloudWatch agent and awslogs for the voting app hosts"
  policy      = data.aws_iam_policy_document.ec2.json
}

resource "aws_iam_role_policy_attachment" "ec2" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups

  #checkov:skip=CKV_AWS_338:a week of logs suits a course stack; a year would bill storage for nothing
  #checkov:skip=CKV_AWS_158:CloudWatch Logs encrypts every log group at rest by default; a customer managed key adds cost and a key policy for no gain here

  name              = "${var.name_prefix}${each.key}"
  retention_in_days = 7
}

# Rejected traffic only: it shows the security groups at work.
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "REJECT"
  max_aggregation_interval = 60
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.this["vpc-flow"].arn
  iam_role_arn             = aws_iam_role.flow_log.arn

  tags = {
    Name = "${var.name_prefix}vpc-flow"
  }
}

# The flow log service assumes this role only for this account's flow logs,
# as AWS recommends against the confused deputy problem.
data "aws_iam_policy_document" "flow_log_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_log" {
  statement {
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
    resources = [
      aws_cloudwatch_log_group.this["vpc-flow"].arn,
      "${aws_cloudwatch_log_group.this["vpc-flow"].arn}:*",
    ]
  }
}

resource "aws_iam_role" "flow_log" {
  name               = "${var.name_prefix}vpc-flow"
  assume_role_policy = data.aws_iam_policy_document.flow_log_assume.json
}

resource "aws_iam_role_policy" "flow_log" {
  name   = "${var.name_prefix}vpc-flow"
  role   = aws_iam_role.flow_log.id
  policy = data.aws_iam_policy_document.flow_log.json
}

resource "aws_sns_topic" "alarms" {
  #checkov:skip=CKV_AWS_26:CloudWatch alarms cannot publish to a topic encrypted with the AWS managed SNS key; a customer managed key is not worth it here

  name = "${var.name_prefix}alarms"
}

# AWS sends a confirmation email; alarms arrive only after the owner confirms it.
resource "aws_sns_topic_subscription" "alarms" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.name_prefix}${each.key}"
  alarm_description   = "${each.value.host}: ${each.value.desc}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.periods
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  treat_missing_data  = each.value.missing
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = merge(
    { InstanceId = aws_instance.this[each.value.host].id },
    each.value.gauge ? { metric_type = "gauge" } : {},
  )
}
