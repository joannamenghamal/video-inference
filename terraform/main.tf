# Configure AWS Provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# S3 Bucket for Video Inputs
resource "aws_s3_bucket" "video_input" {
  bucket = "video-input-gvill005-devops"

  tags = {
    Name        = "Video Input Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for JSON Outputs
resource "aws_s3_bucket" "json_output" {
  bucket = "json-output-gvill005-devops"

  tags = {
    Name        = "JSON Output Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# S3 Bucket for Logs
resource "aws_s3_bucket" "logs" {
  bucket = "logs-gvill005-devops"

  tags = {
    Name        = "Processing Logs Bucket"
    Project     = "DevOps Video Pipeline"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "video-pipeline-vpc"
    Project = "DevOps Video Pipeline"
  }
}

# Public Subnet - AZ a
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "video-pipeline-public-subnet-a"
    Project = "DevOps Video Pipeline"
  }
}

# Public Subnet - AZ b (required for multi-AZ ASG)
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-west-2b"
  map_public_ip_on_launch = true

  tags = {
    Name    = "video-pipeline-public-subnet-b"
    Project = "DevOps Video Pipeline"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "video-pipeline-igw"
    Project = "DevOps Video Pipeline"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "video-pipeline-public-rt"
    Project = "DevOps Video Pipeline"
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Security Group
resource "aws_security_group" "ec2" {
  name        = "video-processor-sg"
  description = "Security group for video processing EC2 instances"
  vpc_id      = aws_vpc.main.id

  # Allow SSH from anywhere (for debugging - restrict in production)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "video-processor-sg"
    Project = "DevOps Video Pipeline"
  }
}

# IAM Role for EC2 to access S3 and SQS
resource "aws_iam_role" "ec2_s3_access" {
  name = "video-processor-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "video-processor-ec2-role"
    Project = "DevOps Video Pipeline"
  }
}

# IAM Policy for S3 and SQS Access
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-sqs-access-policy"
  role = aws_iam_role.ec2_s3_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.video_input.arn}",
          "${aws_s3_bucket.video_input.arn}/*",
          "${aws_s3_bucket.json_output.arn}",
          "${aws_s3_bucket.json_output.arn}/*",
          "${aws_s3_bucket.logs.arn}",
          "${aws_s3_bucket.logs.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.video_jobs.arn
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "video-processor-instance-profile"
  role = aws_iam_role.ec2_s3_access.name
}

# SQS Queue for video processing jobs
resource "aws_sqs_queue" "video_jobs" {
  name                       = "video-processing-jobs"
  visibility_timeout_seconds = 300  # 5 min - time allowed to process one video
  message_retention_seconds  = 86400

  tags = {
    Name    = "video-processing-jobs"
    Project = "DevOps Video Pipeline"
  }
}

# SQS Queue Policy - allow S3 to send messages when a video is uploaded
resource "aws_sqs_queue_policy" "video_jobs" {
  queue_url = aws_sqs_queue.video_jobs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.video_jobs.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.video_input.arn
          }
        }
      }
    ]
  })
}

# S3 Event Notification -> SQS on .mp4 upload
resource "aws_s3_bucket_notification" "video_input" {
  bucket = aws_s3_bucket.video_input.id

  queue {
    queue_arn     = aws_sqs_queue.video_jobs.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp4"
  }

  depends_on = [aws_sqs_queue_policy.video_jobs]
}

# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Launch Template - replaces the single EC2 instance
resource "aws_launch_template" "processor" {
  name_prefix   = "video-processor-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.medium"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  # Use placeholders for bash variables to avoid Terraform interpolation conflicts.
  # sed replaces them at runtime with the actual Terraform-resolved values.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    yum update -y
    yum install -y docker aws-cli jq
    systemctl start docker
    systemctl enable docker

    docker pull gvill005/video-processor:latest

    # Write worker script with placeholders for bash variables
    cat > /usr/local/bin/video-worker.sh << 'WORKER'
    #!/bin/bash
    QUEUE_URL="__QUEUE_URL__"
    INPUT_BUCKET="__INPUT_BUCKET__"
    OUTPUT_BUCKET="__OUTPUT_BUCKET__"
    REGION="us-west-2"

    while true; do
      MSG=$(aws sqs receive-message \
        --queue-url "$QUEUE_URL" \
        --region "$REGION" \
        --max-number-of-messages 1 \
        --wait-time-seconds 20 \
        --output json 2>/dev/null)

      MESSAGES=$(echo "$MSG" | jq -r '.Messages // empty')
      [ -z "$MESSAGES" ] && continue

      RECEIPT=$(echo "$MSG" | jq -r '.Messages[0].ReceiptHandle')
      S3_KEY=$(echo "$MSG" | jq -r '.Messages[0].Body | fromjson | .Records[0].s3.object.key')
      BASENAME=$(basename "$S3_KEY" .mp4)

      VIDEO_FILE="/tmp/$BASENAME.mp4"
      OUTPUT_FILE="/tmp/$BASENAME.json"
      OUTPUT_KEY="results/$BASENAME.json"

      aws s3 cp "s3://$INPUT_BUCKET/$S3_KEY" "$VIDEO_FILE" --region "$REGION"

      docker run --rm \
        -v "$VIDEO_FILE:/app/input.mp4:ro" \
        -v "/tmp:/tmp" \
        gvill005/video-processor:latest \
        python process_video.py /app/input.mp4 "$OUTPUT_FILE"

      aws s3 cp "$OUTPUT_FILE" "s3://$OUTPUT_BUCKET/$OUTPUT_KEY" --region "$REGION"

      aws sqs delete-message \
        --queue-url "$QUEUE_URL" \
        --receipt-handle "$RECEIPT" \
        --region "$REGION"

      rm -f "$VIDEO_FILE" "$OUTPUT_FILE"
    done
    WORKER

    # Substitute Terraform-resolved values into the worker script
    sed -i "s|__QUEUE_URL__|${aws_sqs_queue.video_jobs.url}|g" /usr/local/bin/video-worker.sh
    sed -i "s|__INPUT_BUCKET__|${aws_s3_bucket.video_input.bucket}|g" /usr/local/bin/video-worker.sh
    sed -i "s|__OUTPUT_BUCKET__|${aws_s3_bucket.json_output.bucket}|g" /usr/local/bin/video-worker.sh
    chmod +x /usr/local/bin/video-worker.sh

    # Systemd service so the worker restarts automatically on failure
    cat > /etc/systemd/system/video-worker.service << 'SERVICE'
    [Unit]
    Description=Video Processing Worker
    After=docker.service
    Requires=docker.service

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/video-worker.sh
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable video-worker
    systemctl start video-worker
  EOF
  )

  tags = {
    Name    = "video-processor-launch-template"
    Project = "DevOps Video Pipeline"
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "processor" {
  name                = "video-processor-asg"
  min_size            = 0
  max_size            = 5
  desired_capacity    = 0
  vpc_zone_identifier = [aws_subnet.public.id, aws_subnet.public_b.id]

  launch_template {
    id      = aws_launch_template.processor.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "video-processor-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "DevOps Video Pipeline"
    propagate_at_launch = true
  }
}

# Scale-out policy - add one instance
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "video-processor-scale-out"
  autoscaling_group_name = aws_autoscaling_group.processor.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 120
}

# Scale-in policy - remove one instance
resource "aws_autoscaling_policy" "scale_in" {
  name                   = "video-processor-scale-in"
  autoscaling_group_name = aws_autoscaling_group.processor.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 120
}

# CloudWatch Alarm - scale out when any job is in the queue
resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "video-queue-scale-out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Scale out when there are jobs waiting in the queue"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    QueueName = aws_sqs_queue.video_jobs.name
  }
}

# CloudWatch Alarm - scale in when queue has been empty for 3 minutes
resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "video-queue-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Scale in when queue has been empty for 3 consecutive minutes"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]

  dimensions = {
    QueueName = aws_sqs_queue.video_jobs.name
  }
}

# Outputs
output "sqs_queue_url" {
  value       = aws_sqs_queue.video_jobs.url
  description = "SQS queue URL for video processing jobs"
}

output "asg_name" {
  value       = aws_autoscaling_group.processor.name
  description = "Name of the Auto Scaling Group"
}
