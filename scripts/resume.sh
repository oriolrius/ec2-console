#!/usr/bin/env bash
# Start the (stopped) ec2-console again and print how to connect.
# The public IP changes on every start. Chrome Remote Desktop needs no change.
# Uses the Terraform state of this checkout, else the "ec2-console" CF stack.
set -euo pipefail
cd "$(dirname "$0")/.."
id=$(terraform -chdir=terraform output -raw instance_id 2>/dev/null || true)
if [ -z "$id" ]; then
  id=$(aws ec2 describe-instances --output text \
    --filters Name=tag:aws:cloudformation:stack-name,Values=ec2-console \
              Name=instance-state-name,Values=stopped,stopping,running \
    --query 'Reservations[0].Instances[0].InstanceId')
fi
if [ -z "$id" ] || [ "$id" = None ]; then echo "resume: no ec2-console instance found" >&2; exit 1; fi
echo "starting $id ..."
aws ec2 start-instances --instance-ids "$id" --query 'StartingInstances[0].CurrentState.Name' --output text
aws ec2 wait instance-running --instance-ids "$id"
ip=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
if [ -f terraform/terraform.tfstate ]; then
  terraform -chdir=terraform apply -refresh-only -auto-approve -input=false >/dev/null || true
fi
echo "running: $id   public IP: $ip"
echo "ssh -i ec2-key.pem ubuntu@$ip"
