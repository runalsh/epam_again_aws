#==== prov ======================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = var.region
}



#========== S3 ==============

# resource "aws_s3_bucket" "terraform_state" {
#    bucket = "statebucket-myy"
#    lifecycle {
#      prevent_destroy = true
#    }
#     versioning {
#       enabled = true
#     }
#  } 

terraform {
  backend "s3" {
    bucket = "statebucket-myy"
    key    = "statebucket-runner-myy/terraform.tfstate"
    region = "eu-central-1"
  }
}



#============ RES ==========

data "aws_ami" "amazon_linux" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

owners = ["099720109477"] # Canonical

}

resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key_runner" {
  key_name   = var.key_name_runner
  public_key = tls_private_key.example.public_key_openssh
}

#========== perm ============
# locals {
#   role_policy_arns = [
#     "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
#     "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
#   ]
# }

# resource "aws_iam_role_policy_attachment" "runner-policy" {
#   count = length(local.role_policy_arns)

#   role       = aws_iam_role.runner-iam-role.name
#   policy_arn = element(local.role_policy_arns, count.index)
# }

resource "aws_iam_role_policy" "runner-iam-role-policy" {
  name = "${var.prefix}-EC2-Inline-Policy-runner"
  role = aws_iam_role.runner-iam-role.id
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "ssm:GetParameter",
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "ec2:DescribeVolumes",
            "ec2:DescribeTags",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams",
            "cloudwatch:PutMetricData",
            "ssm:PutParameter"
          ],
          "Resource" : "*"
        }
      ]
    }
  )
}

resource "aws_iam_role" "runner-iam-role" {
  name = "${var.prefix}-runner-node"

  assume_role_policy = <<POLICY
    {
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
    }
POLICY
}

resource "aws_iam_role_policy_attachment" "runner_attach-ssm-managed-policy" {
  role       = aws_iam_role.runner-iam-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "runner_profile" {
  name = "${var.runnername}-profile"
  role = aws_iam_role.runner-iam-role.name
}

resource "aws_iam_role_policy_attachment" "runner_attach-cw-agent-managed-policy" {
  role       = aws_iam_role.runner-iam-role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "runner-cloudwatch-logs-full-access" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
  role       = aws_iam_role.runner-iam-role.name
}



#========== VPC =======================

resource "aws_internet_gateway" "igw_runner_main" {
  vpc_id = aws_vpc.vpc_runner_main.id
  tags = {
    name = "${var.prefix}-main-runner-igw"
  }
}

resource "aws_security_group" "sg_runner_main" {
  name   = "${var.prefix}-aws-sec-group-runner-main"
  vpc_id = aws_vpc.vpc_runner_main.id


  dynamic "ingress" {
    # for_each = ["22","80","443"]
    for_each = ["22"]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    name = "${var.prefix}-main-runner-sec-group"
  }
}

data "aws_availability_zones" "aviable_zones" {
  state = "available"
}

resource "aws_subnet" "runner-subnets" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.vpc_runner_main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = data.aws_availability_zones.aviable_zones.names[count.index]
  map_public_ip_on_launch = "true"

  tags = {
    name = "${var.prefix}-subnets-vpcmain"
  }
}

resource "aws_vpc" "vpc_runner_main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    name = "${var.prefix}-runner-vpcmain"
  }
}

resource "aws_route_table" "vpc_runner_route" {
  vpc_id = aws_vpc.vpc_runner_main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_runner_main.id
  }
  tags = {
    name = "${var.prefix}-runner-vpc-route"
  }
}

resource "aws_route_table_association" "vpc_runner_route_assoc" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.runner-subnets[count.index].id
  route_table_id = aws_route_table.vpc_runner_route.id
}

### =======================c  cloudwatch

resource "aws_cloudwatch_log_group" "runner-logs" {
  name              = "/aws/ec2/${var.runnername}/"
  retention_in_days = 3
}

resource "aws_cloudwatch_log_stream" "runner-logs-stream" {
 name           = "${var.runnername}-runner-logs-stream"
 log_group_name = "${aws_cloudwatch_log_group.runner-logs.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu_high_runner" {
  alarm_name          = "${var.runnername}-cpu_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "80"
  insufficient_data_actions = []
  alarm_actions = ["${aws_sns_topic.alarmrunner.arn}"]

    dimensions = {
        InstanceId = aws_instance.runner.id
    }
}

resource "aws_cloudwatch_metric_alarm" "mem_high_runner" {
  alarm_name          = "${var.runnername}-mem_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = "60"
  statistic           = "Average"
  threshold           = "80"
  insufficient_data_actions = []
  alarm_actions = ["${aws_sns_topic.alarmrunner.arn}"]

    dimensions = {
        InstanceId = aws_instance.runner.id
    }
}

resource "aws_cloudwatch_metric_alarm" "disk_low_runner" {
  alarm_name        = "${var.runnername}-low-disk-alarm"
  alarm_description = "Alerts on disk space lower 10%"

  comparison_operator       = "GreaterThanOrEqualToThreshold"
  threshold                 = "90"
  evaluation_periods        = "1"
  period                    = "60"
  statistic                 = "Average"
  namespace                 = "CWAgent"
  metric_name               = "disk_used_percent"
  insufficient_data_actions = []
  alarm_actions = ["${aws_sns_topic.alarmrunner.arn}"]

  dimensions = {
        InstanceId = aws_instance.runner.id
    }
}

resource "aws_sns_topic" "alarmrunner" {
  name            = "${var.prefix}-runner-alarms"
  delivery_policy = <<EOF
  {
  "http": {
    "defaultHealthyRetryPolicy": {
      "minDelayTarget": 20,
      "maxDelayTarget": 20,
      "numRetries": 3,
      "numMaxDelayRetries": 0,
      "numNoDelayRetries": 0,
      "numMinDelayRetries": 0,
      "backoffFunction": "linear"
    },
    "disableSubscriptionOverrides": false,
    "defaultThrottlePolicy": {
      "maxReceivesPerSecond": 1
      }
    }
  }
  EOF

  provisioner "local-exec" {
    command = "aws sns subscribe --topic-arn ${self.arn} --protocol email --notification-endpoint ${var.alarms_email}"
  }
}


# =========  RUNNER  ======================

data "aws_ami" "ecs_optimized" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-*"]
  }

  owners = [
    "amazon"
  ]
}

resource "aws_instance" "runner" {
    ami                     = data.aws_ami.ecs_optimized.id
    instance_type           = var.runner_type
    subnet_id      = aws_subnet.runner-subnets.0.id
    vpc_security_group_ids  = [aws_security_group.sg_runner_main.id]
    key_name                = var.key_name2
    iam_instance_profile  = "${aws_iam_instance_profile.runner_profile.name}"

    user_data_replace_on_change =  true
    user_data = data.template_cloudinit_config.cloudinit_config.rendered

    # lifecycle {
    # create_before_destroy = true
    # }

    tags = { 
        Name = "${var.runnername}" 
    }
}  

data "template_file" "cloudinit_main" {
  template = file("./ci.yml")
}

data "template_cloudinit_config" "cloudinit_config" {
  gzip          = false
  base64_encode = false
  part {
    filename     = "./ci.yml"
    content_type = "text/cloud-config"
    content      = data.template_file.cloudinit_main.rendered
  }
}
