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

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true
  
  tags = {
    Name    = "video-pipeline-public-subnet"
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

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
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

# IAM Role for EC2 to access S3
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

# IAM Policy for S3 Access
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access-policy"
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
      }
    ]
  })
}

# Attach AWS managed policy for SSM access
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_s3_access.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "video-processor-instance-profile"
  role = aws_iam_role.ec2_s3_access.name
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

# EC2 Instance
 resource "aws_instance" "processor" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = "video-processor-key"

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    # Update system
    yum update -y
    
    # Install Docker
    yum install -y docker
    systemctl start docker
    systemctl enable docker
    
    # Add ec2-user to docker group
    usermod -a -G docker ec2-user
    
    # Pull Docker image v3
    docker pull gvill005/video-processor:v3
    
    # Get SQS queue URL
    QUEUE_URL=$(aws sqs get-queue-url --queue-name video-processing-queue --region us-west-2 --query 'QueueUrl' --output text)
    
    # Start container in polling mode (runs in background)
    docker run -d --restart unless-stopped \
      -e AWS_DEFAULT_REGION=us-west-2 \
      gvill005/video-processor:v3 \
      python process_video.py poll "$QUEUE_URL" json-output-gvill005-devops
    
    echo "Setup complete!" > /home/ec2-user/setup-complete.txt
  EOF
  
  tags = {
    Name    = "video-processor-instance"
    Project = "DevOps Video Pipeline"
  }
}

# Output the EC2 public IP
output "ec2_public_ip" {
  value       = aws_instance.processor.public_ip
  description = "Public IP of the EC2 instance"
}

# SQS Queue for video processing jobs
resource "aws_sqs_queue" "video_processing" {
  name                       = "video-processing-queue"
  visibility_timeout_seconds = 600  # 10 minutes - should be longer than max video processing time
  message_retention_seconds  = 86400  # 24 hours
  
  tags = {
    Name    = "video-processing-queue"
    Project = "DevOps Video Pipeline"
  }
}

# S3 Event Notification to SQS
resource "aws_s3_bucket_notification" "video_upload" {
  bucket = aws_s3_bucket.video_input.id
  
  queue {
    queue_arn     = aws_sqs_queue.video_processing.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp4"
  }
}

# SQS Queue Policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "video_processing" {
  queue_url = aws_sqs_queue.video_processing.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "SQS:SendMessage"
        Resource = aws_sqs_queue.video_processing.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.video_input.arn
          }
        }
      }
    ]
  })
}

# Update IAM policy to allow EC2 to access SQS
resource "aws_iam_role_policy" "sqs_access" {
  name = "sqs-access-policy"
  role = aws_iam_role.ec2_s3_access.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.video_processing.arn
      }
    ]
  })
}