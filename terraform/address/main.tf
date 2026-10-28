# Static public IP (Elastic IP) for the ec2-console workstation, in its OWN
# state. The workspace root (..) only associates it, so a workspace
# `terraform destroy` + `apply` keeps the same address. Releasing it is a
# separate, explicit step: `terraform -chdir=terraform/address destroy`.
#
# Create this first, then the workspace. Not needed with `static_ip = false`.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "Must match the workspace region (terraform/terraform.tfvars)"
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Name tag prefix (same as the workspace name)"
  type        = string
  default     = "ec2-console"
}

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = { Name = "${var.name}-eip" }
}

output "eip_allocation_id" {
  description = "Allocation ID the workspace associates with the instance"
  value       = aws_eip.this.id
}

output "public_ip" {
  description = "The static public IP"
  value       = aws_eip.this.public_ip
}
