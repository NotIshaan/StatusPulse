provider "aws" {
  region = var.aws_region
}

# Fetch the latest Ubuntu 22.04 Free Tier AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Create SSH Key Pair in AWS
resource "aws_key_pair" "deployer" {
  key_name   = "statuspulse-deployer-key"
  public_key = file(pathexpand(var.public_key_path))
}

# Security Group / Firewall
resource "aws_security_group" "statuspulse_sg" {
  name        = "statuspulse_sg"
  description = "Allow custom SSH, HTTP, and HTTPS inbound traffic"

  ingress {
    description = "Custom SSH"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The EC2 Instance
resource "aws_instance" "web" {
  ami             = data.aws_ami.ubuntu.id
  instance_type   = "t2.micro" # Free tier eligible
  key_name        = aws_key_pair.deployer.key_name
  security_groups = [aws_security_group.statuspulse_sg.name]

  # Pass the hardening script to run on boot
  user_data = file("${path.module}/userdata.sh")

  tags = {
    Name = "StatusPulse-Server"
  }
}
