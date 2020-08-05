data "aws_vpc" "default"{
  default = true 
}
data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}
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


data "template_file" "user_data" {
    template = file("${path.module}/user-data.sh")

    vars = {
    server_port = var.server_port
    #db_address  = data.terraform_remote_state.db.outputs.address
    #db_port     = data.terraform_remote_state.db.outputs.port
    }
}

resource "aws_launch_configuration" "example" {
  image_id        = "ami-0ac80df6eff0e70b5"
  instance_type   = var.instance_type
  security_groups = [aws_security_group.instance.id]
  user_data       = data.template_file.user_data.rendered 

  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids
  target_group_arns    = [aws_lb_target_group.asg.arn]
  health_check_type    = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.custom_tags

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

# data "terraform_remote_state" "db" {
#   backend = "s3"

#   config = {
#     bucket = var.db_remote_state_bucket
#     key    = var.db_remote_state_key
#     region = "us-east-1"
#   }

# }



// terraform {
//   backend "s3" {
//     bucket = "chysome-terraform-state-file-bucket"
//     key    = "stage/services/webserver-cluster/terraform.tfstate"
//     region = "us-east-1"

//     dynamodb_table = "chysome-terraform-state-file-lock"
//     encrypt        = true
//   }
// }
