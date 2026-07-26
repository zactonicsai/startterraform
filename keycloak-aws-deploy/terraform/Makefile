# Convenience wrapper. `make help` lists everything.
.PHONY: help init fmt validate plan apply destroy-plan destroy output refresh health

TFVARS ?= terraform.tfvars

help:
	@echo "Keycloak on AWS - Terraform"
	@echo ""
	@echo "  make init          download providers, set up the backend"
	@echo "  make fmt           format all .tf files"
	@echo "  make validate      syntax + type check"
	@echo "  make plan          preview changes, saved to tfplan"
	@echo "  make apply         apply the SAVED plan (review it first!)"
	@echo "  make output        show outputs"
	@echo "  make health        check target health"
	@echo ""
	@echo "  make destroy-plan  preview the teardown"
	@echo "  make destroy       apply the saved destroy plan"
	@echo ""
	@echo "  Use a different var file:  make plan TFVARS=example-dev.tfvars"

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: fmt
	terraform validate

# -out=tfplan matters: `terraform apply` on its own re-plans, and the world
# may have changed since you looked. Applying a saved plan guarantees you get
# exactly what you reviewed.
plan: validate
	terraform plan -var-file=$(TFVARS) -out=tfplan
	@echo ""
	@echo ">>> READ THE PLAN ABOVE. On a fresh build, 'to destroy' must be 0."

apply:
	@test -f tfplan || (echo "No tfplan found. Run 'make plan' first."; exit 1)
	terraform apply tfplan
	@rm -f tfplan

output:
	terraform output

refresh:
	terraform refresh -var-file=$(TFVARS)

health:
	@aws elbv2 describe-target-health \
		--target-group-arn $$(terraform output -raw target_group_arn) \
		--query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
		--output table

destroy-plan:
	@echo ">>> Before this works you must set, in $(TFVARS):"
	@echo ">>>   enable_deletion_protection = false"
	@echo ">>> and apply that change first:"
	@echo ">>>   terraform apply -var-file=$(TFVARS) -target=aws_db_instance.main -target=aws_lb.main"
	@echo ""
	terraform plan -destroy -var-file=$(TFVARS) -out=destroy.tfplan
	@echo ""
	@echo ">>> Resources that will be DESTROYED:"
	@terraform show -json destroy.tfplan | \
		jq -r '.resource_changes[] | select(.change.actions[0]=="delete") | .address' | sort

destroy:
	@test -f destroy.tfplan || (echo "No destroy.tfplan. Run 'make destroy-plan' first."; exit 1)
	@echo ">>> Have you taken a manual RDS snapshot? See docs/DESTROY.md"
	@read -p ">>> Type the word DESTROY to continue: " ans; \
		[ "$$ans" = "DESTROY" ] || (echo "Aborted."; exit 1)
	terraform apply destroy.tfplan
	@rm -f destroy.tfplan
	@echo ""
	@echo ">>> Now run the orphan hunt: ../cli/linux-mac/orphan-hunt.sh"
