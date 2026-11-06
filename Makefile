# DataHub + Trino lab for Semantic Operator.
#
# `make up` builds the STARTING POINT of the lab, nothing more:
#   kind cluster, Postgres, Trino with the retail data loaded, DataHub with the
#   tables ingested and the steward metadata seeded, the toolbox pod, and the
#   chat UI with its identity gateway.
#
# Semantic Operator is NOT installed and no model exists. Those are the lab:
# follow docs/lab-guide.md (or docs/lab-steps.md) and run each step yourself.
#
# Every target is idempotent, so a failed `make up` can simply be re-run.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

CLUSTER   ?= semantic-lab
CONTEXT   := kind-$(CLUSTER)
LAB_DIR   := $(CURDIR)
DH_CHARTS := $(LAB_DIR)/datahub/charts
# The Semantic Operator commit this lab is written and tested against. The
# toolbox installs ossiectl from it, and the guide has you clone it to build
# the operator. Semantic Operator has no tagged release yet.
OPERATOR_REF ?= 4fd7057ef3a67b3711a927e639e6a78550d6c945
TOOLBOX   ?= semantic-lab/toolbox:dev
KUBECTL   := kubectl --context $(CONTEXT)
HELM      := helm --kube-context $(CONTEXT)

# Optional: export these before `make up` (or `make chat`) to configure the LLM.
OPENROUTER_API_KEY ?=
LLM_MODEL          ?=

.DEFAULT_GOAL := help

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

.PHONY: up
up: cluster platform data datahub toolbox catalog chat ## Build the whole starting point (about 15 minutes the first time)
	@echo
	@echo "Lab ready. Nothing of Semantic Operator is installed yet: that is your first step."
	@echo "  DataHub UI   http://localhost:9002   (datahub / datahub)"
	@echo "  Trino UI     http://localhost:8080   (user: lab)"
	@echo "  Open WebUI   http://localhost:3000"
	@echo "  Toolbox      kubectl -n lab exec -it deploy/toolbox -- bash"

.PHONY: cluster
cluster: ## Create the kind cluster (sets your kubectl context to kind-semantic-lab)
	@mkdir -p $(LAB_DIR)/work $(LAB_DIR)/.tmp
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER)'; then \
	  echo "kind cluster $(CLUSTER) exists"; \
	else \
	  sed 's#@LAB_WORK@#$(LAB_DIR)/work#' kind/cluster.yaml.tmpl > .tmp/cluster.yaml; \
	  kind create cluster --name $(CLUSTER) --config .tmp/cluster.yaml --wait 120s; \
	fi
	@kubectl config use-context $(CONTEXT) >/dev/null

.PHONY: platform
platform: ## Postgres and Trino in namespace lakehouse
	$(KUBECTL) apply -f platform/namespaces.yaml
	$(KUBECTL) -n lakehouse create configmap lab-data-sql --from-file=platform/load-data.sql \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f platform/postgres.yaml
	$(KUBECTL) -n lakehouse rollout status statefulset/postgres --timeout=5m
	$(KUBECTL) apply -f platform/trino.yaml
	$(KUBECTL) -n lakehouse rollout status deploy/trino --timeout=10m

.PHONY: data
data: ## Load the retail tables into iceberg.osi_demo (runs platform/load-data.sql in Trino)
	@# Trino answers HTTP before it accepts queries, so wait for a real one.
	@for i in $$(seq 60); do \
	  $(KUBECTL) -n lakehouse exec deploy/trino -- trino --execute 'SELECT 1' >/dev/null 2>&1 && break; sleep 5; \
	done
	$(KUBECTL) -n lakehouse exec deploy/trino -- trino --output-format=ALIGNED -f /etc/lab/load-data.sql \
	  2> >(grep -vE 'jline|system terminal|dumb terminal' >&2)

.PHONY: datahub
datahub: ## DataHub, OpenSearch and Kafka in namespace datahub (5 to 10 minutes)
	$(KUBECTL) apply -f platform/namespaces.yaml
	$(KUBECTL) -n datahub create secret generic datahub-postgres \
	  --from-literal=postgres-password="$$($(KUBECTL) -n lakehouse get secret postgres -o jsonpath='{.data.DATAHUB_PASSWORD}' | base64 -d)" \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(HELM) upgrade --install prerequisites $(DH_CHARTS)/datahub-prerequisites-0.3.0.tgz \
	  -n datahub -f datahub/prereqs-values.yaml --wait --timeout 15m
	$(KUBECTL) apply -f datahub/kafka.yaml
	$(KUBECTL) -n datahub rollout status statefulset/prerequisites-kafka --timeout=5m
	$(HELM) upgrade --install datahub $(DH_CHARTS)/datahub-1.0.3.tgz \
	  -n datahub -f datahub/values.yaml --wait --timeout 20m
	$(KUBECTL) apply -f datahub/nodeport.yaml

.PHONY: toolbox
toolbox: ## Build the toolbox image (ossiectl + DataHub CLI), load it, start the pod
	docker build --build-arg OPERATOR_REF=$(OPERATOR_REF) -t $(TOOLBOX) $(LAB_DIR)/toolbox
	kind load docker-image $(TOOLBOX) --name $(CLUSTER)
	@mkdir -p $(LAB_DIR)/.tmp
	sed -e "s#@LAB_UID@#$$(id -u)#" -e "s#@LAB_GID@#$$(id -g)#" toolbox/toolbox.yaml.tmpl > .tmp/toolbox.yaml
	$(KUBECTL) apply -f platform/namespaces.yaml -f .tmp/toolbox.yaml
	$(KUBECTL) -n lab rollout restart deploy/toolbox
	$(KUBECTL) -n lab rollout status deploy/toolbox --timeout=2m

.PHONY: catalog
catalog: ## Ingest the Trino tables into DataHub, then seed the steward metadata
	$(KUBECTL) -n datahub delete job datahub-ingest-trino datahub-annotate --ignore-not-found
	$(KUBECTL) apply -f catalog/ingest.yaml
	$(KUBECTL) -n datahub wait --for=condition=complete job/datahub-ingest-trino --timeout=10m
	$(KUBECTL) -n datahub create configmap steward-metadata \
	  --from-file=catalog/steward-metadata.yaml --from-file=catalog/annotate.py \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f catalog/annotate-job.yaml
	$(KUBECTL) -n datahub wait --for=condition=complete job/datahub-annotate --timeout=10m
	$(KUBECTL) -n datahub logs job/datahub-annotate --tail=5

.PHONY: chat
chat: ## Open WebUI (OpenRouter) and the identity gateway in namespace chat
	$(KUBECTL) apply -f platform/namespaces.yaml
	@if [ -n "$(OPENROUTER_API_KEY)" ]; then \
	  $(KUBECTL) -n chat create secret generic openrouter --from-literal=OPENAI_API_KEY="$(OPENROUTER_API_KEY)" \
	    --dry-run=client -o yaml | $(KUBECTL) apply -f - ; \
	else echo "OPENROUTER_API_KEY not set: create the chat/openrouter Secret later (see the guide)"; fi
	$(KUBECTL) apply -f chat/gateway.yaml -f chat/open-webui.yaml
	@if [ -n "$(LLM_MODEL)" ]; then \
	  $(KUBECTL) -n chat patch configmap open-webui --type merge -p '{"data":{"DEFAULT_MODELS":"$(LLM_MODEL)"}}'; \
	  $(KUBECTL) -n chat rollout restart deploy/open-webui; fi
	$(KUBECTL) -n chat rollout status deploy/semantic-gateway --timeout=2m
	$(KUBECTL) -n chat rollout status deploy/open-webui --timeout=10m

.PHONY: status
status: ## Show every lab pod
	$(KUBECTL) get pods -A -o wide | grep -vE 'kube-system|local-path-storage'

.PHONY: down
down: ## Delete the kind cluster (./work, your model files, is kept)
	kind delete cluster --name $(CLUSTER)
