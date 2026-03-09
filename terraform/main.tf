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
# resource "aws_instance" "processor" {
#  ami                    = data.aws_ami.amazon_linux.id
#  instance_type          = "t3.medium"
#  subnet_id              = aws_subnet.public.id
#  vpc_security_group_ids = [aws_security_group.ec2.id]
#  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
#  
#  user_data = <<-EOF
#    #!/bin/bash
#    # Update system
#    yum update -y
#    
#    # Install Docker
#    yum install -y docker
#    systemctl start docker
#    systemctl enable docker
#    
#    # Pull Docker image
#    docker pull gvill005/video-processor:latest
#    
#    echo "Setup complete!" > /home/ec2-user/setup-complete.txt
#  EOF
#  
#  tags = {
#    Name    = "video-processor-instance"
#    Project = "DevOps Video Pipeline"
#  }
#}
#
## Output the EC2 public IP
#output "ec2_public_ip" {
#  value       = aws_instance.processor.public_ip
#  description = "Public IP of the EC2 instance"
#}