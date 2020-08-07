variable "server_port" {
  description = "The port the server will use for http requests"
  type        = number
  default     = 8080
}
variable "s3" {
  description = "The alb access log bucket"
  type        = string
  default     = "chysome-terraform-state-file-bucket"
}

variable "cluster_name" {
  description = "The name to use for all the cluster resources"
  type        = string
}
variable "db_remote_state_bucket" {
  description = "The name of S3 bucket for the database's remote state"
  type        = string
}
variable "db_remote_state_key" {
  description = "The path for the database's remote state in S3"
  type        = string
}
variable "instance_type" {
  description = "The type of EC2 Instances to run (e.g t2.micro)"
  type        = string
}
variable "min_size" {
  description = "The minimum number of EC2 instances in the ASG"
  type        = number
}
variable "max_size" {
  description = "The maximum number of EC2 instances in the ASG"
  type        = number
}

locals {
  http_port = 80
  ssh_port  = 22
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips = ["0.0.0.0/0"]
}

variable "custom_tags" {
  description = "Custom tags to set on the instances in the ASG"
  type        = map(string)
  default     = {}
}

variable "enable_autoscaling" {
  description = "if set to true, enable autoscaling"
  type        = bool
}
variable "give_neo_cloudwatch_full_access"{
  description = "If True, neo gets full access to cloudwatch"
  type        = bool
}
variable "enable_new_user_data" {
  description = "If set to true, use the new User Data Script"
  type        = bool
}

  




