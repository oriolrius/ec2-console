#!/usr/bin/env bash
# Prints the public IP of the ec2-console instance for the Ansible inventory.
# First match wins: JUPYTER_IP, the live IP of the Terraform instance (the
# Terraform output can be stale after a start without static_ip), the Terraform
# output, or the running instance of the "ec2-console" CloudFormation stack.
cd "$(dirname "$0")/.." || exit 1

ip="${JUPYTER_IP:-}"
if [ -z "$ip" ]; then
  id=$(terraform -chdir=terraform output -raw instance_id 2>/dev/null)
  if [ -n "$id" ]; then
    ip=$(aws ec2 describe-instances --instance-ids "$id" --output text \
      --query 'Reservations[0].Instances[0].PublicIpAddress' 2>/dev/null)
    [ "$ip" = "None" ] && ip=""
  fi
fi
[ -n "$ip" ] || ip=$(terraform -chdir=terraform output -raw public_ip 2>/dev/null)
if [ -z "$ip" ]; then
  ip=$(aws ec2 describe-instances --output text \
    --filters Name=tag:aws:cloudformation:stack-name,Values=ec2-console \
              Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].PublicIpAddress' 2>/dev/null)
  [ "$ip" = "None" ] && ip=""
fi
if [ -z "$ip" ]; then
  echo "host-ip.sh: no running ec2-console found (set JUPYTER_IP)" >&2
  exit 1
fi
echo "$ip"
