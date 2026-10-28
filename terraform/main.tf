# EC2 cloud development workstation (Ubuntu 24.04) — Terraform equivalent of
# ../cloudformation.yaml. Provisioning handled separately by Ansible.
#
# Difference from the CF template: it does not rely on a default VPC (course
# sandbox accounts have none), so it creates a minimal public network.
#
# Static IP (default): the Elastic IP lives in its own state (./address) and
# this root only associates it, so destroying this workspace keeps the IP.
# Create ./address first, or set `static_ip = false` in terraform.tfvars.

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
  type    = string
  default = "eu-west-1"
}

variable "name" {
  description = "Name tag (CF: stack name)"
  type        = string
  default     = "ec2-console"
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH access"
  type        = string
  default     = "ec2-key"
}

variable "instance_type" {
  description = "EC2 instance type (4+ vCPU). t3a.xlarge is the cheapest AMD burstable option."
  type        = string
  default     = "t3a.xlarge"
  validation {
    condition     = contains(["t3a.xlarge", "c6a.xlarge", "t3.xlarge", "c6i.xlarge", "m6a.xlarge"], var.instance_type)
    error_message = "instance_type must be one of t3a.xlarge, c6a.xlarge, t3.xlarge, c6i.xlarge, m6a.xlarge."
  }
}

variable "static_ip" {
  description = "Associate the Elastic IP from ./address (same IP across stop/start and rebuilds). false = a new public IP on every start, no EIP cost."
  type        = bool
  default     = true
}

variable "ubuntu_ami" {
  description = "Ubuntu 24.04 LTS AMI ID (eu-west-1)"
  type        = string
  default     = "ami-03957e4cfe042cca1"
}

# --- Minimal public network ---------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = var.name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = var.name }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Same resources as cloudformation.yaml ------------------------------------

resource "aws_security_group" "this" {
  name        = var.name
  description = "SSH and application ports"
  vpc_id      = aws_vpc.this.id

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    protocol    = "tcp"
    from_port   = 8888
    to_port     = 8889
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "this" {
  ami                    = var.ubuntu_ami
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]

  # A shutdown from inside (idle-stop) stops the instance; it never terminates it.
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size = 25
    volume_type = "gp3"
  }

  tags = { Name = var.name }

  depends_on = [aws_route_table_association.public]
}

# --- Static public IP (Elastic IP owned by ./address) -------------------------

locals {
  address_state     = "${path.module}/address/terraform.tfstate"
  eip_allocation_id = var.static_ip ? try(data.terraform_remote_state.address[0].outputs.eip_allocation_id, null) : null
  public_ip         = var.static_ip ? try(data.terraform_remote_state.address[0].outputs.public_ip, aws_instance.this.public_ip) : aws_instance.this.public_ip
}

# Read only if it exists; otherwise the precondition below explains what to do.
data "terraform_remote_state" "address" {
  count   = var.static_ip && fileexists(local.address_state) ? 1 : 0
  backend = "local"
  config  = { path = local.address_state }
}

resource "aws_eip_association" "this" {
  count         = var.static_ip ? 1 : 0
  allocation_id = local.eip_allocation_id
  instance_id   = aws_instance.this.id

  lifecycle {
    precondition {
      condition     = local.eip_allocation_id != null
      error_message = "static_ip = true but there is no Elastic IP yet. Create it first: terraform -chdir=terraform/address init && terraform -chdir=terraform/address apply. Or set static_ip = false in terraform/terraform.tfvars."
    }
  }
}

output "public_ip" {
  description = "Public IP address (the Elastic IP when static_ip = true)"
  value       = local.public_ip
}

output "static_ip" {
  description = "Whether the Elastic IP is associated"
  value       = var.static_ip
}

output "instance_id" {
  description = "Instance ID (for stop/start)"
  value       = aws_instance.this.id
}

output "ssh_command" {
  description = "SSH into the instance"
  value       = "ssh -i ec2-key.pem ubuntu@${local.public_ip}"
}

output "ansible_command" {
  description = "Run Ansible provisioning"
  value       = "uv run ansible-playbook playbook.yml"
}
