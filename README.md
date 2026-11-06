# Semantic Operator lab: DataHub, Apache Ossie, and Trino on kind

A hands-on lab for learning [Semantic Operator](https://github.com/kubeflow/semantic-operator)
by doing every step yourself on a laptop.

This repository holds only the lab. It does not contain Semantic Operator. You clone the
operator during the lab and install it like any user would.

## What you do

`make up` builds the starting point and nothing more:

- a kind cluster with Trino holding five retail tables (Iceberg, about 1.6 million sales lines)
- DataHub with those tables ingested and a steward's descriptions, glossary terms, and PII tags
- a toolbox pod with `ossiectl` and the DataHub CLI
- Open WebUI for chat, using OpenRouter, behind a gateway that sets the caller's role

Then you do the rest with `kubectl`, `helm`, `docker`, `curl`, the Trino CLI, and the DataHub UI:

1. Install Semantic Operator from source.
2. Derive an Apache Ossie model from Trino plus DataHub with `ossiectl`.
3. Certify it: keys, joins, dimensions, metrics, roles, views.
4. Publish it and watch the operator validate, drift check, and publish it.
5. Query it over REST and read the SQL it generates.
6. Exercise governance, versioning, catalog changes, and schema drift.
7. Chat with your data over MCP and see why the LLM never writes SQL.

## Guides

- [Lab steps at a glance](docs/lab-steps.md). The numbered checklist, one line per step.
- [Hands-on lab with DataHub and Trino](docs/lab-guide.md). The full guide with expected output and explanations.

## Quick start

Needs Docker with at least 12 GB of memory and 4 CPUs, plus `kind`, `kubectl`, `helm`, `make`,
and `git`. Ports 3000, 8080, and 9002 on `127.0.0.1` must be free.

```bash
git clone https://github.com/tarekabouzeid/kf-semantic-operator-lab
cd kf-semantic-operator-lab
make up        # about 15 minutes the first time
make status
```

| UI | Address | Login |
|---|---|---|
| DataHub | <http://localhost:9002> | `datahub` / `datahub` |
| Trino | <http://localhost:8080> | user `lab` |
| Open WebUI | <http://localhost:3000> | none |

`make down` deletes the cluster. Your files in `work/` stay.

## Layout

| Path | What it is |
|---|---|
| `Makefile` | Every command `make up` runs. `OPERATOR_REF` pins the Semantic Operator commit |
| `kind/` | The kind cluster config |
| `platform/` | Postgres, Trino, and `load-data.sql`, the SQL that creates the tables |
| `datahub/` | DataHub and its OpenSearch and Kafka. Helm values and the vendored charts |
| `catalog/` | DataHub ingestion recipe and `steward-metadata.yaml`, the seeded business metadata |
| `toolbox/` | The image and pod you work from |
| `operator/values.yaml` | The Helm values you install Semantic Operator with |
| `chat/` | Open WebUI and the identity gateway in front of the semantic server |
| `model/` | A finished model, to compare with yours |
| `work/` | Your files. Shared with the toolbox pod as `/work` |
| `docs/` | The guides |

## Versions

| Component | Version |
|---|---|
| Semantic Operator | commit `4fd7057` (no tagged release yet) |
| Trino | 483 |
| DataHub | v1.6.0 (chart 1.0.3, prerequisites 0.3.0) |
| Open WebUI | v0.6.36 |
| Postgres | 16 |

Licensed under Apache 2.0. The DataHub charts in `datahub/charts/` are the upstream charts,
vendored unchanged.
