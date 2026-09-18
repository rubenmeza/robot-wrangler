.PHONY: help preflight test robot-wrangler robot-destroy robot-ssh robot-attach robot-auth robot-ip robot-status robot-update robot-update-status
.DEFAULT_GOAL := help

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## check deps, secrets, local tailnet, and doctl auth
	@./scripts/preflight.sh

test: ## run script tests (requires python3; optional Provisioner container smoke)
	@./scripts/test-common.sh
	@python3 scripts/test-robot-update.py
	@./scripts/test-provision.sh

robot-wrangler: ## provision the box, join the tailnet, push the agent token (idempotent)
	@./scripts/robot-wrangler.sh

robot-destroy: ## tear the box down (tofu destroy)
	@set -a; . ./.env; set +a; tofu destroy

robot-ssh: ## ssh into the box over the tailnet
	@./scripts/robot-ssh.sh

robot-attach: ## mosh in and attach the 'robot' tmux session
	@./scripts/robot-attach.sh

robot-auth: ## (re)push the Claude Code subscription token over SSH
	@./scripts/robot-auth.sh

robot-ip: ## print the box's tailnet IP
	@./scripts/robot-ip.sh

robot-update: ## confirm and start persistent OS package + Herdr maintenance
	@./scripts/robot-update.sh

robot-update-status: ## report the latest maintenance operation
	@./scripts/robot-update.sh status

robot-status: ## show droplet + tailnet status
	@doctl compute droplet list --tag-name robot --format Name,PublicIPv4,Status,Region,Memory,VCPUs || true
	@echo
	@tailscale status 2>/dev/null | grep -E 'robot' || echo "robot not visible on the tailnet"
