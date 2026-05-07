variable "aws_region" {
  description = "The AWS region to deploy to"
  default     = "us-east-1"
}

variable "ssh_port" {
  description = "Custom SSH port for security hardening"
  default     = 2222
}

variable "public_key_path" {
  description = "Path to your local SSH public key"
  default     = "~/.ssh/id_ed25519.pub"
}
