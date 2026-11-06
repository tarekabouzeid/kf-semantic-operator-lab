# Handover: bring up the lab on this machine

Instructions for a Claude Code session running on the lab owner's machine, in a clone of
this repository (`main`). Read `README.md`, `Makefile`, `docs/lab-steps.md`, and
`docs/lab-guide.md` before doing anything.

## Goal

1. Bring up the starting point with `make up` and get every pod healthy (`make status`).
2. Prove the operator path end to end, as the guide describes it:
   - Stage 3. Clone Semantic Operator at the pinned commit into `./semantic-operator`, build
     the manager and server images, `kind load` them, `helm install` with `operator/values.yaml`.
   - Stage 4. In the toolbox pod, `ossiectl derive ... -enrich datahub` must report
     `enriched 5/5 tables from DataHub (3 sensitive columns, 0 deprecated)`.
   - Stage 6. Apply `model/semanticmodel.yaml` and reach
     `VALIDATED=True PUBLISHED=True DRIFT=False`.
   - Stage 7. One REST query through `kubectl port-forward` returns rows.
3. Undo step 2 afterwards, because installing the operator is the owner's hands-on exercise:
   `kubectl delete -f model/semanticmodel.yaml`, then
   `helm uninstall semantic-operator -n semantic-system`. Leave the starting point running.
4. Fix anything that breaks in the lab files. Keep `docs/lab-guide.md`, `docs/lab-steps.md`,
   and `README.md` in sync with every fix. Commit and push to `main`.
5. Finish by telling the owner the lab is ready, with the three UI addresses, and list every
   fix you made.

Ask the owner before anything destructive outside this lab, such as deleting other kind
clusters or Docker images that the lab did not create.

## What was verified and what was not

The lab was built in a cloud sandbox where kind could not run. Each layer was tested as plain
Docker containers using the lab's own configs.

Verified:
- Postgres 18 init (roles, databases, Iceberg JDBC tables). Trino 484 data load
  (`platform/load-data.sql`, about 30 seconds). Iceberg views.
- DataHub v1.8.0 with the env rendered from chart 1.1.9: the system-update job and GMS, with
  metadata-service authentication on. OpenSearch 2.19.7. Kafka 4.4.0.
- The toolbox image: ingestion, `catalog/annotate.py`, and `ossiectl derive -enrich datahub`.
- The operator manager and server binaries (at the pinned commit) against a real
  kube-apiserver and Trino: publish, views, REST, governance, drift, and MCP through the
  nginx gateway config.

Never tested:
- The kind cluster itself: `kind/cluster.yaml.tmpl`, host ports 9002, 3000, and 8080, the
  `work/` hostPath mount, and the toolbox UID and GID templating.
- The Helm installs of DataHub and Semantic Operator on kind, and NetworkPolicy behaviour.
- Open WebUI v0.13.0. Its image could not be pulled in the sandbox. Check that it starts and
  that the Stage 10 menu names in the guide (Admin Panel, Settings, External Tools,
  MCP Streamable HTTP, Chat Controls, Advanced Params, Function Calling Native) match the
  v0.13.0 UI. Fix the guide where they differ. An OpenRouter key is not needed for this check.

## Known gotchas, already handled. Do not undo them

- Trino's Iceberg JDBC catalog needs its two Postgres tables created up front, in the init
  script in `platform/postgres.yaml`. The `iceberg_type` column is what allows views.
- Trino answers HTTP before it accepts queries, so `make data` waits for `SELECT 1`.
- DataHub prerequisites chart 0.3.1 renders only with `opensearch.serviceMonitor.enabled: false`.
  OpenSearch disk watermarks are switched off for laptops with full disks.
- DataHub 1.8 needs metadata-service authentication on. Clients send
  `Authorization: Basic __datahub_system:<system_client_secret>` from the Secret
  `datahub-auth-secrets` in namespace `datahub`. `make toolbox` copies it into the Secret
  `datahub-token` in namespace `lab` as `DATAHUB_TOKEN`, so `make datahub` must run before
  `make toolbox`. The order in `make up` does this.
- Postgres 18 mounts its volume at `/var/lib/postgresql`, not `/var/lib/postgresql/data`.
- Semantic Operator has no tagged release. The lab pins commit
  `4fd7057ef3a67b3711a927e639e6a78550d6c945` (`OPERATOR_REF` in the Makefile). The published
  v0.1.1 images predate features the lab teaches, so do not switch to them.
- The DataHub CLI in the toolbox is 1.7.0.19, the newest stable release on PyPI. It talks to
  the v1.8.0 server.

## Conventions

- `make up` builds only the starting point. Everything involving the operator is the owner's
  own hands-on work with native tools. Do not add scripts that do the owner's steps.
- Docs prose: short declarative sentences, no em dashes, no semicolons joining clauses.
- When something fails, report the step, the command, and the error. Fix the root cause.
