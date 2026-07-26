# Convenience wrapper. `make help` lists everything.
SHELL := /bin/bash
VARS  ?= terraform.tfvars

.PHONY: help init fmt validate plan apply snapshot destroy output clean

help:
	@echo "  make init      - download providers"
	@echo "  make validate  - syntax + provider checks"
	@echo "  make plan      - write tf.plan and SHOW IT. Always read this."
	@echo "  make apply     - apply the saved plan"
	@echo "  make output    - show URLs and commands"
	@echo "  make snapshot  - snapshot the NiFi data volumes  <-- BEFORE destroy"
	@echo "  make destroy   - tear it down"
	@echo ""
	@echo "  Single node:  make plan VARS=example-single.tfvars"
	@echo "  Cluster:      make plan VARS=example-cluster.tfvars"

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: init
	terraform validate

plan: validate
	terraform plan -var-file=$(VARS) -out=tf.plan
	@echo ""
	@echo "  Read the plan above. Look for 'must be replaced' on aws_ebs_volume -"
	@echo "  that would destroy in-flight NiFi data."

apply:
	@test -f tf.plan || (echo "no tf.plan - run 'make plan' first" && exit 1)
	terraform apply tf.plan
	@rm -f tf.plan

output:
	terraform output

# NiFi keeps in-flight data on those volumes. Snapshot before you destroy,
# every single time. This is the step people skip once and regret.
snapshot:
	@echo "==> snapshotting NiFi data volumes"
	@for v in $$(terraform output -json data_volume_ids | jq -r '.[]'); do \
	  s=$$(aws ec2 create-snapshot --volume-id $$v \
	        --description "pre-destroy $$(date -u +%FT%TZ)" \
	        --query SnapshotId --output text); \
	  echo "    $$v -> $$s"; \
	done
	@echo "==> confirm they reach 'completed' before destroying:"
	@echo "    aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,State,Progress]' --output table"

destroy:
	@echo ""
	@echo "  Did you run 'make snapshot'? terraform destroy DELETES the data volumes."
	@echo ""
	@read -p "  Type yes to continue: " a; [ "$$a" = yes ] || exit 1
	terraform plan -destroy -var-file=$(VARS)
	@read -p "  Read that. Type DESTROY to proceed: " a; [ "$$a" = DESTROY ] || exit 1
	terraform destroy -var-file=$(VARS)
	@echo ""
	@echo "  Now check for strays:  ../cli/orphan-hunt.sh"

clean:
	rm -rf .terraform tf.plan
