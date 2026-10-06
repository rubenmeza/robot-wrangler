.PHONY: help preflight test robot-wrangler robot-destroy robot-ssh robot-attach robot-auth robot-ip robot-status robot-update robot-update-status tailnet-plan tailnet-apply enroll open close status revoke
.DEFAULT_GOAL := help

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

preflight: ## check deps, secrets, local tailnet, and doctl auth
	@./scripts/preflight.sh

test: ## validate Tailnet policy and run script tests (optional Provisioner container smoke)
	@tofu -chdir=tailnet init -backend=false -input=false -lockfile=readonly
	@tofu -chdir=tailnet validate
	@./scripts/test-common.sh
	@python3 scripts/test-robot-update.py
	@python3 scripts/test-personal-host.py
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

tailnet-plan: ## validate policy tests and preview the whole Tailnet policy change
	@set -eu; set -a; . ./.env; set +a; \
		: "$${TAILSCALE_API_KEY:?set TAILSCALE_API_KEY in .env}"; \
		: "$${TAILSCALE_TAILNET:?set TAILSCALE_TAILNET in .env}"; \
		: "$${TF_VAR_tailnet_owner:?set TF_VAR_tailnet_owner in .env}"; \
		tofu -chdir=tailnet init -input=false; \
		tofu -chdir=tailnet plan -input=false

tailnet-apply: ## apply the whole Tailnet policy (separate state from the Robot server)
	@set -eu; set -a; . ./.env; set +a; \
		: "$${TAILSCALE_API_KEY:?set TAILSCALE_API_KEY in .env}"; \
		: "$${TAILSCALE_TAILNET:?set TAILSCALE_TAILNET in .env}"; \
		: "$${TF_VAR_tailnet_owner:?set TF_VAR_tailnet_owner in .env}"; \
		tofu -chdir=tailnet init -input=false; \
		tofu -chdir=tailnet apply

enroll: ## enroll this Arch/Omarchy machine as a Personal host
	@./scripts/personal-host.sh enroll

export DEVICE
revoke: ## revoke a lost Device key, Tailnet node and T3 Pairings everywhere
	@./scripts/personal-host.sh revoke "$${DEVICE:-}"

open: ## open SSH and T3 Tailnet doors on this Open-by-hand Personal host
	@./scripts/personal-host.sh open

close: ## hard-close inbound doors while keeping agents and outbound sessions running
	@./scripts/personal-host.sh close

status: ## report this Personal host's actual doors, inbound handlers and live work
	@./scripts/personal-host.sh status
