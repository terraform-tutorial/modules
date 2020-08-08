data "aws_vpc" "default"{
  default = true 
}
data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}
data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-1"
  }
}
data "aws_iam_policy_document" "cloudwatch_read_only" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*"
    ]
    resources = ["*"]
  }
}
data "aws_iam_policy_document" "cloudwatch_full_access" {
  statement {
    effect = "Allow"
    actions = ["cloudwatch:*"]
    resources = ["*"]
  }
}
data "template_file" "user_data" {
  # count = var.enable_new_user_data ? 0 : 1
  template = file("${path.module}/user-data.sh")

  vars = {
  server_port = var.server_port
  db_address  = data.terraform_remote_state.db.outputs.address
  db_port     = data.terraform_remote_state.db.outputs.port
  server_text = var.server_text
  }
}
# data "template_file" "user_data_new" {
#   count = var.enable_new_user_data ? 1 : 0
#   template = file("${path.module}/user-data-new.sh")

#   vars = {
#   server_port = var.server_port
#   }
# }
resource "aws_security_group" "instance" {
  name        = "${var.cluster_name}-instance"
}
resource "aws_security_group_rule" "app_access" {
  type              = "ingress" 
  security_group_id = aws_security_group.instance.id
  from_port         = var.server_port
  to_port           = var.server_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
  }
resource "aws_security_group_rule" "allow_ssh_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instance.id
  from_port         = local.ssh_port
  to_port           = local.ssh_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
  }
resource "aws_security_group_rule" "allow_ssh_outbound" {
  type              = "egress" 
  security_group_id = aws_security_group.instance.id
  from_port         = local.any_port
  to_port           = local.any_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
}

resource "aws_security_group" "alb" {
  name        = "${var.cluster_name}-alb"
}
resource "aws_security_group_rule" "allow_http_inbound" {
    type              = "ingress"
    security_group_id = aws_security_group.alb.id
    from_port         = local.http_port
    to_port           = local.http_port
    protocol          = local.tcp_protocol
    cidr_blocks       = local.all_ips
  }
resource "aws_security_group_rule" "allow_http_outbound" {
    type        = "egress" 
    security_group_id = aws_security_group.alb.id
    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
}
resource "aws_launch_configuration" "example" {
  image_id        = var.ami
  instance_type   = var.instance_type
  security_groups = [aws_security_group.instance.id]
  user_data = data.template_file.user_data.rendered
  # user_data       = (
  #   length(data.template_file.user_data[*]) > 0
  #   ? data.template_file.user_data[0].rendered
  #   : data.template_file.user_data_new[0].rendered
  # )

  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_autoscaling_group" "example" {
  # Explicitly depend on the launch configuration's name so each time it's
  # replaced, this ASG is also replaced
  name                 = "${var.cluster_name}-${aws_launch_configuration.example.name}"
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids
  target_group_arns    = [aws_lb_target_group.asg.arn]
  health_check_type    = "ELB"

  min_size = var.min_size
  max_size = var.max_size
  # Wait for at least this many instances to pass health checks before
  # considering the ASG deployment complete
  min_elb_capacity = var.min_size
  
  lifecycle {
    create_before_destroy = true 
  }

  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = {
      for key, value in var.custom_tags:
      key => upper(value)
      if key != "Name"
    }

    content {
      key = tag.key
      value = tag.value
      propagate_at_launch = true
    }
  }
}
resource "aws_lb" "example" {
  name               = "${var.cluster_name}-example"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default.ids
  security_groups    = [aws_security_group.alb.id]
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = local.http_port  
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
  condition {
    path_pattern {
      values = ["*"]
    }   
  }
}
resource "aws_lb_target_group" "asg" {
  name     = "terraform-asg-example"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                    = "/"
    protocol                = "HTTP"
    matcher                 = 200
    interval                = 15
    timeout                 = 3
    healthy_threshold        = 2
    unhealthy_threshold      = 2

  }
}

resource "aws_autoscaling_schedule" "scale_out_during_business_hours" {
  count = var.enable_autoscaling ? 1 : 0
  scheduled_action_name = "scale-out-during-business-hours"
  min_size = 2
  max_size = 10
  desired_capacity = 10
  recurrence = "0 9 * * *"
  autoscaling_group_name = module.webserver-cluster.asg_name
}
resource "aws_autoscaling_schedule" "scale_in-at-night" {
  count = var.enable_autoscaling ? 1 : 0
  scheduled_action_name = "scale-in-at-night"
  min_size = 2
  max_size = 10
  desired_capacity = 2
  recurrence = "0 17 * * *"
  autoscaling_group_name = module.webserver-cluster.asg_name
}

resource "aws_cloudwatch_metric_alarm" "high_cpu_utilization" {
  alarm_name = "${var.cluster_name}-high-cpu-utilization"
  namespace = "AWS/EC2"
  metric_name = "CPUUtilization"

  dimensions = {
    AutoScalingGroupName = "aws_autoscaling_group.example.name"
  }
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 1
  period = 300
  statistic = "Average"
  threshold = 90
  unit = "Percent"
}
# If statement
resource "aws_cloudwatch_metric_alarm" "low_cpu_credit_balance" {
  count = format("%.1s", var.instance_type) == "t" ? 1 : 0

  alarm_name = "${var.cluster_name}-low-cpu-credit-baance"
  namespace = "AWS/EC2"
  metric_name = "CPUCreditBalance"

  dimensions = {
    AutoScalingGroupName = "aws_autoscaling_group.example.name"
  }
  comparison_operator = "LessThanThreshold"
  evaluation_periods = 1
  period = 300
  statistic = "Minimum"
  threshold = 10
  unit = "Count"
}
resource "aws_iam_policy" "cloudwatch_read_only" {
  name = "cloudwatch-read-only"
  policy = data.aws_iam_policy_document.cloudwatch_read_only.json
}
resource "aws_iam_policy" "cloudwatch_full_access" {
  name = "cloudwatch-read-only"
  policy = data.aws_iam_policy_document.cloudwatch_full_access.json
}


# If-else statement 
resource "aws_iam_user_policy_attachment" "neo_cloudwatch_full_access" {
  count = var.give_neo_cloudwatch_full_access ? 1 : 0

  user = aws_iam_user.example[0].name
  policy_arn = aws_iam_policy.cloudwatch_full_access.arn  
}
resource "aws_iam_user_policy_attachment" "neo_cloudwatch_read_only" {
  count = var.give_neo_cloudwatch_full_access ? 0 : 1

  user = aws_iam_user.example[0].name
  policy_arn = aws_iam_policy.cloudwatch_read_only.arn  
}
resource "aws_iam_user" "example" {
  for_each = toset(var.user_names)
  name     = each.value
}






// terraform {
//   backend "s3" {
//     bucket = "chysome-terraform-state-file-bucket"
//     key    = "stage/services/webserver-cluster/terraform.tfstate"
//     region = "us-east-1"

//     dynamodb_table = "chysome-terraform-state-file-lock"
//     encrypt        = true
//   }
// }
