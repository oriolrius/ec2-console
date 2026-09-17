# DBAI address root — allocates exactly ONE persistent Elastic IP per
# environment. The workspace consumes `allocation_id`; it never owns aws_eip
# (ENV-R007). Address cleanup is a distinct operation, never part of a
# workspace destroy.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ec2-console"
      Course      = "dbai"
      ManagedBy   = "terraform"
      Environment = var.environment_id
      Component   = "address"
    }
  }
}

variable "aws_region" {
  description = "AWS region for the course environment."
  type        = string
  default     = "eu-west-1"
}

variable "environment_id" {
  description = "Per-student/instructor environment identity (non-secret)."
  type        = string
}

resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.environment_id}-eip"
  }
}

output "eip_allocation_id" {
  description = "Allocation ID the workspace consumes to associate the EIP."
  value       = aws_eip.this.id
}

output "public_ip" {
  description = "The persistent public IP address."
  value       = aws_eip.this.public_ip
}
