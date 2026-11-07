# Hands-on lab with DataHub and Trino

This lab is for learning by doing. A script builds the starting point and then gets out of
the way. Every step that involves Semantic Operator, Apache Ossie, or `ossiectl` is a command
you type yourself with `kubectl`, `helm`, `docker`, `curl`, the Trino CLI, or the DataHub UI.

> **You start with raw tables and a business catalog. You finish with a governed semantic layer that an AI agent can use, and you know what each piece does.**

Want only the commands? [Lab steps at a glance](lab-steps.md) is the same lab as a numbered
checklist.

## What you will learn

- What DataHub contributes to a semantic model, and what it cannot.
- How `ossiectl derive` turns an engine schema plus DataHub metadata into an Apache Ossie model.
- Which parts of a model only a person can write, and why.
- What the operator does when you apply a model: validate, compile, drift check, publish, create views.
- How the server turns a request for certified metrics into exactly one SQL statement.
- What "the LLM never writes SQL" means when you chat with your data.

## How the pieces fit

There are two paths. You walk the authoring path once per model change. The query path runs
for every question.

```
AUTHORING PATH (you, in this lab)

  Trino information_schema ──┐
   (tables, columns, types)  ├──► ossiectl derive ──► draft model ──► you certify it ──► kubectl apply
  DataHub ───────────────────┘     (in the toolbox)    (Apache Ossie)  (keys, joins,       │
   (descriptions, glossary                                              metrics, roles)    ▼
    terms, PII tags)                                                          Semantic Operator
                                                                              validate, compile,
                                                                              drift check, publish

QUERY PATH (every question)

  Open WebUI ──► LLM (OpenRouter) ──MCP──► identity gateway ──► semantic server ──one SQL──► Trino
                 picks metrics and         sets the caller's    plans from the
                 dimensions by name        role                 published model
```

DataHub is on the authoring path only. The server never calls it. What DataHub knows reaches
queries because `ossiectl` wrote it into the model, a person reviewed it, and the operator
published it.

## What runs where

| Namespace | What runs there | Who installs it |
|---|---|---|
| `lakehouse` | Postgres (Iceberg catalog and DataHub store), Trino with the retail tables | `make up` |
| `datahub` | DataHub GMS and UI, OpenSearch, Kafka | `make up` |
| `lab` | The toolbox pod with `ossiectl` and the DataHub CLI | `make up` |
| `chat` | Open WebUI and the identity gateway | `make up` |
| `semantic-system` | Semantic Operator and the semantic server | **you, in Stage 3** |

The data is five TPC-DS retail tables in `iceberg.osi_demo`. They hold about 1.6 million sales
lines across 12 stores in Tennessee and Texas, from 2000 to 2002.

## Before you start

You need Docker, [kind](https://kind.sigs.k8s.io/), `kubectl`, `helm`, `make`, and `git`.
Give Docker at least 12 GB of memory and 4 CPUs. The lab uses about 10 GB once running, most
of it DataHub. A machine with 24 GB of RAM is comfortable.

Ports 3000, 8080, and 9002 on `127.0.0.1` must be free.

For the chat stage you need an [OpenRouter](https://openrouter.ai/) API key and a model that
supports tool calling. You can decide on both later.

## Stage 0. Build the starting point

**Goal.** Get a realistic company setup on your laptop without doing any of the work this lab
teaches. A real team already has a warehouse, a data catalog, and people who know what the
columns mean. You need the same, so you can spend the lab on the semantic layer.

**What happens.** `make up` runs the Makefile targets in order. It creates the kind cluster,
starts Postgres and Trino, loads five retail tables into Iceberg, installs DataHub with its
search and message queue, ingests the table definitions into DataHub, seeds the steward's
descriptions and tags, builds the toolbox pod, and starts the chat UI. It stops before
anything about Semantic Operator, because that is the part you do.


Clone the lab and build it. Run every host command in this guide from the lab directory.

```bash
git clone https://github.com/tarekabouzeid/kf-semantic-operator-lab
cd kf-semantic-operator-lab
make up
```

The first run takes about 15 minutes, mostly image pulls and DataHub's first start. It
creates the kind cluster `semantic-lab`, loads the data, starts DataHub, ingests the tables
into DataHub, seeds what a data steward recorded about them, and starts the chat UI.

If a step fails, run `make up` again. Every step is safe to repeat.

**Verify.**

```bash
kubectl config current-context
make status
```

The context is `kind-semantic-lab`. Every pod is `Running` or `Completed`. Nothing runs in
`semantic-system` yet.

Open the three UIs to confirm they answer.

| UI | Address | Login |
|---|---|---|
| DataHub | <http://localhost:9002> | `datahub` / `datahub` |
| Trino | <http://localhost:8080> | user `lab` |
| Open WebUI | <http://localhost:3000> | none |

Nothing in this stage is secret. Read the lab's `Makefile` to see every command `make up` ran.

## Stage 1. Look at the raw data

**Goal.** Feel the problem before you fix it. A semantic layer exists because raw tables
cannot tell you which column means revenue or how to join safely. You run one plausible query
and see it return wrong numbers with no warning.

**What happens.** You query Trino directly, the way an analyst or an LLM that writes SQL
would. The query joins sales to stores and divides revenue by headcount. The join repeats
each store's headcount on every sales line, so the denominator is inflated. You keep the two
wrong numbers to compare with the certified ones in Stage 7.


Start where an analyst or an LLM would start, with the tables. Open the Trino CLI inside the
Trino pod.

```bash
kubectl -n lakehouse exec -it deploy/trino -- trino --catalog iceberg --schema osi_demo
```

Run these at the `trino:osi_demo>` prompt.

```sql
SHOW TABLES;
DESCRIBE store_sales;
SELECT count(*) FROM store_sales;
```

`store_sales` has 23 columns. Count the ones that look like money. There are at least seven,
including `ss_sales_price`, `ss_ext_sales_price`, `ss_net_paid`, and `ss_net_profit`. The table
does not tell you which one Finance calls revenue.

Now ask a business question the way an LLM writing SQL usually would. What is revenue per
employee in each state?

```sql
SELECT s.s_state,
       sum(ss.ss_ext_sales_price) / sum(s.s_number_employees) AS revenue_per_employee
FROM store_sales ss
JOIN store s ON s.s_store_sk = ss.ss_store_sk
GROUP BY 1 ORDER BY 1;
```

```
 s_state | revenue_per_employee
---------+----------------------
 TN      |             7.705428
 TX      |             6.899131
```

The query runs and the numbers look plausible. They are wrong by a factor of 80,000 or more.
`s_number_employees` is one value per store, but the join repeats it on every sales line, so
the sum counts each store's headcount hundreds of thousands of times. Nothing warns you.
Keep these two numbers. You will see the correct ones in Stage 7.

Type `quit` to leave the CLI.

## Stage 2. Look at the business meaning in DataHub

**Goal.** See what the catalog knows that the tables do not, and see how `ossiectl` will
read it. This is the raw material for the model's descriptions, synonyms, and access rules.

**What happens.** You browse the same tables in the DataHub UI and find the steward's column
descriptions, glossary terms, and PII tags. Then you open the toolbox pod and call DataHub's
GraphQL API yourself. That is the same call `ossiectl` makes in Stage 4, so nothing about the
tool is hidden. You also learn the dataset URN format that Stage 4 depends on.


The tables tell you names and types. DataHub tells you what they mean. Open
<http://localhost:9002>, sign in, and search for `store_sales`. Open the dataset on the
**Trino** platform. Its full name is `iceberg.osi_demo.store_sales`.

Look at the **Columns** tab. Find three things.

| In DataHub | Example | What it becomes in the model |
|---|---|---|
| A column description | `ss_ext_sales_price` is "what Finance calls revenue" | the field's `description` |
| A glossary term | `ss_ext_sales_price` carries the term **Revenue** | `ai_context.synonyms` on the field |
| A tag | `customer.c_email_address` carries the tag **PII** | an entry in `governance.denyFields` |

Then open **store** and read the description of `s_number_employees`. A steward wrote down the
exact trap from Stage 1. Open **Govern**, then **Glossary**, to see the business vocabulary
under **Retail**.

All of this came from a seed file, `catalog/steward-metadata.yaml`, that `make up` loaded
through DataHub's API. In a company, people build it up in this UI over months.

**Read the same metadata the way `ossiectl` will.** Open a shell in the toolbox pod. You will
use this pod for the rest of the lab.

```bash
kubectl -n lab exec -it deploy/toolbox -- bash
```

```bash
env | grep -E 'ENGINE|DATAHUB|SQL_DIALECT' | sed 's/\(TOKEN=Basic [^:]*:\).*/\1***/' | sort
```

Those variables are all `ossiectl` needs. `DATAHUB_TOKEN` is DataHub's system credential.
DataHub rejects API calls without it, so every client sends it. Now ask DataHub's GraphQL API for the customer
columns. The toolbox image holds `ossiectl`, the DataHub CLI, Python, and the `nano` and `vi` editors, so use Python here.

```bash
python - <<'EOF'
import json, os, urllib.request
urn = "urn:li:dataset:(urn:li:dataPlatform:trino,iceberg.osi_demo.customer,PROD)"
q = {"query": '{ dataset(urn: "%s") { editableSchemaMetadata { editableSchemaFieldInfo '
              '{ fieldPath description globalTags { tags { tag { properties { name } } } } } } } }' % urn}
req = urllib.request.Request(os.environ["DATAHUB_GMS_URL"] + "/api/graphql",
                             json.dumps(q).encode(), {"Content-Type": "application/json",
                                                      "Authorization": os.environ["DATAHUB_TOKEN"]})
for f in json.load(urllib.request.urlopen(req))["data"]["dataset"]["editableSchemaMetadata"]["editableSchemaFieldInfo"]:
    tags = [t["tag"]["properties"]["name"] for t in (f["globalTags"] or {"tags": []})["tags"]]
    print(f["fieldPath"], "|", f["description"], "|", tags)
EOF
```

```
c_email_address | Shopper contact email. | ['PII']
c_first_name | Shopper first name. | ['PII']
c_last_name | Shopper last name. | ['PII']
...
```

This is the same GraphQL API `ossiectl` calls in Stage 4. Notice the dataset URN. DataHub's
Trino ingestion names datasets `<catalog>.<schema>.<table>` on the `trino` platform. You will
pass exactly that to `ossiectl`.

Leave the toolbox shell open in its own terminal.

## Stage 3. Install Semantic Operator

**Goal.** Install the operator the way a user would, from source, and understand its two
parts. After this stage the cluster can accept a `SemanticModel`, but it holds none.

**What happens.** You clone the repository at the pinned commit and build two images from one
Dockerfile. The manager watches `SemanticModel` resources and does the publishing. The server
answers queries and never changes anything. `kind load` copies the images into the cluster
node. `helm install` creates the CRD, both deployments, their service accounts, and the
network policy, using the values in `operator/values.yaml`. The checks confirm the CRD exists
and both pods run.


Work from the lab directory in a second terminal. Semantic Operator has no tagged release
yet, so you install it from source, at the commit this lab was tested with. Clone it into the
lab directory. Git ignores that folder.

```bash
git clone https://github.com/kubeflow/semantic-operator
git -C semantic-operator checkout 4fd7057ef3a67b3711a927e639e6a78550d6c945
```

The checkout holds everything you install. `Dockerfile` builds the images, `charts/` holds the
Helm chart, and `cmd/ossiectl` is the CLI the toolbox already has, built from the same commit.

Build the two images and load them into the kind node.

```bash
docker build --target manager -t semantic-lab/manager:dev semantic-operator
docker build --target server  -t semantic-lab/server:dev  semantic-operator
kind load docker-image semantic-lab/manager:dev semantic-lab/server:dev --name semantic-lab
```

Two images come from one Dockerfile. The **manager** is the operator. It watches
`SemanticModel` resources and publishes compiled models. The **server** answers queries over
REST and MCP. It never changes anything.

Read the Helm values before you install. Every line is commented.

```bash
cat operator/values.yaml
```

Three choices matter.

- `engine` points both components at the lab Trino. The manager connects as
  `semantic-manager` and the server as `semantic-server`. In production these are two engine
  accounts. The manager can read metadata and create views. The server can only `SELECT`.
- `server.auth.mode: header` makes the server trust the `X-Semantic-User` and
  `X-Semantic-Role` headers. That is only safe behind a proxy that sets them. The chat
  gateway is that proxy here. Production uses `mode: jwt`.
- `networkPolicy.allowFrom` lets the `chat` and `lab` namespaces reach the server.
  kind enforces NetworkPolicy through kindnet, which needs nftables support in the host
  kernel. Some kernels lack it, for example WSL2. There the policies are inert and any
  namespace can reach the server. The gateway in Stage 8 still decides the role.

Install it.

```bash
helm install semantic-operator semantic-operator/charts/semantic-operator \
  --namespace semantic-system --create-namespace \
  -f operator/values.yaml --wait
```

**Verify.**

```bash
kubectl get crd semanticmodels.semantic.ossie.io
kubectl -n semantic-system get pods
kubectl -n semantic-system logs deploy/semantic-operator-manager | tail -3
kubectl get semanticmodels -A
```

The CRD exists. Both pods are `Running`. The manager logs `Starting workers`. There are no
models yet. The operator has nothing to do until you write one.

Look at what a `SemanticModel` can hold.

```bash
kubectl explain semanticmodel.spec
kubectl explain semanticmodel.spec.governance.roles
```

`spec.ossie` is the Apache Ossie model, the portable part. `connection`, `governance`,
`views`, and `joins` are operator extensions that sit beside it.

## Stage 4. Derive a draft model

**Goal.** Let the machine write everything a machine can know, so you only write what needs
judgement. You also see the dividing line between the two.

**What happens.** `ossiectl derive` reads table and column names and types from Trino's
`information_schema`. Pass 1 uses Trino alone. Pass 2 adds DataHub, which contributes
descriptions, synonyms from glossary terms, and a `governance` block built from PII tags. You
diff the two files to see exactly what DataHub added. The `TODO` markers and empty lists mark
what is missing, such as keys, joins, and metrics, because no schema or catalog states them.


`ossiectl derive` writes the half of a model a machine can know. Run it in the toolbox
terminal. `/work` in the pod is the `work/` folder of the lab directory on your machine, so
you can open every file in your own editor.

**Pass 1, from Trino only.**

```bash
cd /work
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -model retail -name retail -out scaffold.yaml
```

The tool read `information_schema` through Trino, using the `ENGINE_*` variables you saw in
Stage 2. Every table and column is in the file.

**Pass 2, from Trino plus DataHub.**

```bash
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -enrich datahub -datahub-platform trino -datahub-dataset-prefix iceberg \
  -model retail -name retail -out scaffold-datahub.yaml
```

```
enriched 5/5 tables from DataHub (3 sensitive columns, 0 deprecated)
```

`-datahub-platform trino -datahub-dataset-prefix iceberg` builds the URN you saw in Stage 2.
Get either wrong and the command fails with the URN it tried, rather than quietly writing an
unenriched model. `DATAHUB_URL` and `DATAHUB_TOKEN` are already set in the pod.

**Compare the two passes.**

```bash
diff scaffold.yaml scaffold-datahub.yaml | grep '^>'
```

The physical structure is identical. The enriched file adds descriptions, synonyms from the
glossary terms, and a `governance` block that denies the three PII columns.

```yaml
  governance:
    defaultRole: analyst
    roles:
      - name: analyst
        allowMetrics: ["*"]
        denyFields:
          - "customer.c_email_address"
          - "customer.c_first_name"
          - "customer.c_last_name"
```

A steward's tag in DataHub has become an access rule the compiler will enforce.

**Now look at what is missing.**

```bash
grep -n 'TODO' scaffold-datahub.yaml
grep -n 'metrics: \[\]\|relationships: \[\]\|primary_key: \[\]' scaffold-datahub.yaml
```

There are no primary keys, no relationships, and no metrics. Most fields are not dimensions
yet. The tool did not guess, because none of that is in the schema or the catalog. The next
stage is yours.

## Stage 5. Certify the model

**Goal.** Turn the draft into a model you are willing to put your name on. Certifying means
a person decides what the business terms mean and who may see what. This is the one stage no
tool can do for you.

**What happens.** You edit a copy of the draft in seven steps. Each step adds one kind of
decision: descriptions, keys, groupable fields, joins, metrics, roles, and a view. After each
step `ossiectl validate` runs the operator's own checks offline, so mistakes surface here and
not in the cluster. Edit on your machine at `work/semanticmodel.yaml` with any editor. The
toolbox also has `nano` and `vi` if you prefer to edit inside the pod. Both see the same
file.


Copy the enriched draft and edit the copy in your editor, on your machine, at
`work/semanticmodel.yaml` in the lab directory.

```bash
cp scaffold-datahub.yaml semanticmodel.yaml
```

Make the seven edits below. After each one, check your work from the toolbox.

> **Shortcut.** If you do not want to type the edits, a script can apply all seven to your
> draft. Do the manual edits at least once to learn what each one decides. The script
> writes a new file and refuses to replace one that exists. From the lab directory on your
> machine, run this.
>
> ```bash
> kubectl -n lab exec -i deploy/toolbox -- python - \
>   /work/scaffold-datahub.yaml /work/semanticmodel.auto.yaml < model/certify.py
> kubectl -n lab exec deploy/toolbox -- ossiectl validate -f /work/semanticmodel.auto.yaml
> ```
>
> Use `work/semanticmodel.auto.yaml` wherever the guide says `work/semanticmodel.yaml`. The
> script drops the comments from the draft, because it rewrites the file as plain YAML. Read
> [`model/certify.py`](../model/certify.py) to see exactly what it sets.

```bash
ossiectl validate -f semanticmodel.yaml
```

`validate` runs the same checks the operator runs, offline. It catches a broken join graph or
a metric outside the allowed grammar before anything reaches the cluster.

### Edit 1. Describe the model and point views at Iceberg

**Why.** An agent reads the model description first, so it should say what the model is for and warn about the one trap. `viewDatabase` tells the operator where to create views, and Trino needs the catalog in front.


Under `spec.connection`, set the view schema. Trino needs a catalog in front of it.

```yaml
    viewDatabase: iceberg.semantic_views
```

Under `spec.ossie`, replace the empty description and uncomment `ai_context`.

```yaml
    description: "Retail store sales: revenue, profit, transactions, and store productivity."
    ai_context:
      instructions: >-
        Use the certified metrics. Never compute store productivity from raw
        columns: headcount must be counted once per store.
```

`ai_context.instructions` is what an agent reads first when it lists the model.

### Edit 2. Set the primary keys

**Why.** The planner needs to know which column identifies a row. Without keys it cannot tell when a join repeats a value, which is the Stage 1 bug.


Each dataset has `primary_key: []`. Set them.

| Dataset | `primary_key` |
|---|---|
| `customer` | `["c_customer_sk"]` |
| `date_dim` | `["d_date_sk"]` |
| `item` | `["i_item_sk"]` |
| `store` | `["s_store_sk"]` |
| `store_sales` | `["ss_item_sk", "ss_ticket_number"]` |

The keys are not decoration. The planner uses them to keep a ratio correct across a join.
Without the key on `store`, `store_productivity` in Edit 5 could not be planned safely.

### Edit 3. Choose the dimensions

**Why.** You decide what people may group by. Anything not declared stays out of reach, which keeps agents away from keys and audit columns.


A field can be grouped by only when it declares `dimension`. The tool marked the date columns
already. Add `dimension: {}` to these nine fields, at the same indentation as `expression`.

| Dataset | Fields |
|---|---|
| `store` | `s_state`, `s_store_name` |
| `item` | `i_category`, `i_brand` |
| `date_dim` | `d_year`, `d_month_name` |
| `customer` | `c_birth_country`, `c_preferred_cust_flag`, `c_last_name` |

For example:

```yaml
          - name: "s_state"
            expression:
              dialects:
                - dialect: ANSI_SQL
                  expression: "s_state"
            dimension: {}
            description: "US state of the store."
```

Deciding what is **not** offered matters as much. Surrogate keys and audit columns stay
filterable but are never offered as groupings. You may also delete fields an agent should
never see. The reference model keeps 34 of the 121.

`c_last_name` is personal data, and you still make it a dimension. Being groupable and being
allowed are separate decisions. The model says what can be asked. Governance says who may
ask it. Stage 8 shows the difference.

### Edit 4. Review the inferred joins

**Why.** A wrong join gives wrong numbers silently. The tool only guesses from names, so a person confirms each join and the direction of the many side.


Find `relationships: []`. Below it, the tool listed joins it inferred from `*_sk` naming, as
comments. Review them before you trust them.

- `store_sales_to_customer`, `store_sales_to_item`, `store_sales_to_store` are right.
- `store_to_store_sales` points the wrong way. A relationship goes from the many side (the
  facts) to the one side. Leave it out.
- The join to the calendar is missing. `ss_sold_date_sk` and `d_date_sk` do not share a
  suffix, so naming could not find it.

Replace `relationships: []` and its comments with this list.

```yaml
    relationships:
      - name: store_sales_to_customer
        from: store_sales
        to: customer
        from_columns: [ss_customer_sk]
        to_columns: [c_customer_sk]
      - name: store_sales_to_date_dim
        from: store_sales
        to: date_dim
        from_columns: [ss_sold_date_sk]
        to_columns: [d_date_sk]
      - name: store_sales_to_item
        from: store_sales
        to: item
        from_columns: [ss_item_sk]
        to_columns: [i_item_sk]
      - name: store_sales_to_store
        from: store_sales
        to: store
        from_columns: [ss_store_sk]
        to_columns: [s_store_sk]
```

`validate` rejects a join graph that is not a tree, so a cycle fails here and not in a query.

### Edit 5. Define the metrics

**Why.** A metric is one certified definition of a business number. Everyone, including every agent, now gets the same answer for revenue or productivity.


This is the core of the model and the part no tool can write. Replace `metrics: []` and its
comments.

```yaml
    metrics:
      - name: total_sales
        expression:
          dialects:
            - dialect: ANSI_SQL
              expression: SUM(store_sales.ss_ext_sales_price)
        description: "Revenue: sales after discounts, before tax."
        ai_context:
          synonyms: ["revenue", "sales"]
      - name: total_profit
        expression:
          dialects:
            - dialect: ANSI_SQL
              expression: SUM(store_sales.ss_net_profit)
        description: Net profit.
        ai_context:
          synonyms: ["profit"]
      - name: transaction_count
        expression:
          dialects:
            - dialect: ANSI_SQL
              expression: COUNT(DISTINCT store_sales.ss_ticket_number)
        description: Number of sales tickets (checkouts).
        ai_context:
          synonyms: ["transactions", "tickets", "orders"]
      - name: store_productivity
        expression:
          dialects:
            - dialect: ANSI_SQL
              expression: SUM(store_sales.ss_ext_sales_price) / NULLIF(SUM(store.s_number_employees), 0)
        description: Revenue per employee, each store's headcount counted once.
        ai_context:
          synonyms: ["revenue per employee", "sales per employee"]
```

Look at `store_productivity`. It is the same formula as the wrong query in Stage 1. The
difference is not the formula. The planner sees that the denominator aggregates `store`, the
one side of a join, and computes it separately per store before dividing. That is what the
primary keys in Edit 2 make possible.

`total_sales` uses `ss_ext_sales_price` because the steward tagged it **Revenue** in DataHub.
DataHub informed the choice. A person made it and put it in the model.

### Edit 6. Add roles

**Why.** Roles turn policy into rules the compiler enforces. Who may see which field, and which rows, is decided once here.


The draft has one role, `analyst`. Add a role that sees only Texas and an `admin` role that
sees everything. Append to `spec.governance.roles`.

```yaml
      - name: tx_analyst
        allowMetrics: ["*"]
        denyFields:
          - "customer.c_email_address"
          - "customer.c_first_name"
          - "customer.c_last_name"
        rowFilters:
          - dataset: store
            predicate: "s_state = 'TX'"
      - name: admin
        allowMetrics: ["*"]
```

DataHub tags physical columns. If you add a computed field built from a tagged column, for
example a full name from `c_first_name` and `c_last_name`, the tag does not follow it. Deny
that field yourself. The reference model does exactly this for `customer_full_name`.

The row filter predicate is parsed under a bounded grammar. A typo or a smuggled subquery
fails validation, so a policy file cannot become an injection path.

### Edit 7. Publish a governed view

**Why.** BI tools and notebooks that cannot use REST or MCP can still read a certified result. The view is the same compiled SQL saved in Trino.


Uncomment the `views` block at the end of the file and replace it.

```yaml
  views:
    - name: revenue_by_state
      metrics: [total_sales, store_productivity]
      dimensions: [store.s_state]
      role: admin
```

A view is the same compiled SQL, saved in Trino, for BI tools that do not speak REST or MCP.

**Verify the result.**

```bash
ossiectl validate -f semanticmodel.yaml
```

```
OK: semanticmodel.yaml (model retail, version fc62dda66427)
```

Your version hash differs if your file differs. The version is a hash of the spec, so any
change to the model gives a new version. If `validate` fails, read the message. It names the
spec path, for example `ossie.metrics[3]`. The finished
[reference model](../model/semanticmodel.yaml)
is there to compare with when you are stuck.

**See the Apache Ossie part on its own.**

```bash
ossiectl unwrap -f semanticmodel.yaml | head -20
```

That output is a plain Apache Ossie document, without the operator extensions. Any tool that
reads Ossie can read it.

## Stage 6. Publish the model

**Goal.** Hand the certified model to the operator and watch it become a published, served
artifact. This is the point where a YAML file turns into something other systems can rely on.

**What happens.** `kubectl apply` creates a `SemanticModel`. The manager validates it,
compiles it into a frozen artifact, checks every table and column against Trino for drift,
stores the artifact in a ConfigMap, and creates the governed views in Trino. Each action
reports as a condition on the resource. The server reads only the published ConfigMap, so it
never sees your YAML, the catalog, or the live schema.


Apply the file from your machine, in the second terminal.

```bash
kubectl apply -f work/semanticmodel.yaml
kubectl -n semantic-system get semanticmodels -w
```

```
NAME     VERSION        VALIDATED   PUBLISHED   DRIFT   AGE
retail   fc62dda66427   True        True        False   3s
```

Press Ctrl+C. The operator did five things in those seconds. Read them in the conditions.

```bash
kubectl -n semantic-system get semanticmodel retail \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

```
ViewsReady=True 1 views published
Validated=True Ossie document and planner subset checks passed
DriftDetected=False physical schema matches bindings
Compiled=True compiled model version fc62dda66427
Published=True published sm-retail-compiled
```

1. **Validated** the spec, as `ossiectl validate` did.
2. **Compiled** it into a frozen artifact.
3. **Checked drift.** It described every table through Trino and confirmed every column the
   model uses exists.
4. **Published** the artifact as a ConfigMap labelled with the model version.
5. **Created views** in Trino, as the `semantic-manager` user.

Look at the artifact and the view.

```bash
kubectl -n semantic-system get configmap sm-retail-compiled --show-labels
kubectl -n semantic-system get configmap sm-retail-compiled \
  -o jsonpath='{.data.compiled-model\.json}' | python3 -m json.tool | head -40
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'SHOW CREATE VIEW iceberg.semantic_views.revenue_by_state'
```

The server watches these ConfigMaps. It never reads your YAML, Trino's schema, or DataHub.
It serves only what the operator published.

## Stage 7. Query the model over REST

**Goal.** Prove the payoff. You ask the Stage 1 question again and get the right answer, and
you see that the SQL comes from your definitions and not from a guess.

**What happens.** You port-forward the server and call its REST API as the `analyst` role.
First you list the vocabulary, which is what an agent would see. Then you request metrics and
dimensions by name. The planner turns that request into one SQL statement and Trino runs it.
You also ask for the SQL without running it, check that it is identical on repeat, and hit a
boundary by asking to group by a field you never declared.


Forward the server port, from the second terminal.

```bash
kubectl -n semantic-system port-forward svc/semantic-operator-server 8090:8090 &
H=(-H 'X-Semantic-User: me' -H 'X-Semantic-Role: analyst')
```

**Discover the vocabulary.** This is exactly what an agent sees.

```bash
curl -s localhost:8090/v1/models "${H[@]}" | python3 -m json.tool
curl -s localhost:8090/v1/models/retail/metrics "${H[@]}" | python3 -m json.tool
curl -s localhost:8090/v1/models/retail/dimensions "${H[@]}" | python3 -m json.tool | head -30
```

The descriptions and synonyms from DataHub are in the answers. So are the ones you wrote.

**Ask the Stage 1 question.**

```bash
curl -s -X POST localhost:8090/v1/models/retail/query "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["store_productivity","total_sales"],"dimensions":["store.s_state"]}' | python3 -m json.tool
```

```
"rows": [
    ["TN", "644567.241309", "1516666718.80"],
    ["TX", "1826350.375719", "1510391760.72"]
]
```

Compare with Stage 1. The naive SQL said 7.71 and 6.90. The certified metric says 644,567 and
1,826,350.

**Read the SQL without running it.**

```bash
curl -s -X POST localhost:8090/v1/models/retail/sql "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["store_productivity"],"dimensions":["store.s_state"]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan"]["sql"])'
```

The numerator is summed over sales joined to stores. The denominator is summed over `store`
alone, once per store. A comment on the first line names the model, version, and request
hash. That comment is in Trino's query history, so every statement can be traced to the
model version that produced it. Open <http://localhost:8080> to find it.

**Check determinism.** Run the `/sql` request again. The SQL is identical, byte for byte. The
same request, model version, and role always compile to the same statement.

**Filter, sort, and limit.**

```bash
curl -s -X POST localhost:8090/v1/models/retail/query "${H[@]}" -H 'Content-Type: application/json' -d '{
  "metrics": ["total_sales"],
  "dimensions": ["item.i_category"],
  "filters": [{"field": "date_dim.d_year", "op": "=", "value": 2002}],
  "orderBy": [{"field": "total_sales", "direction": "desc"}],
  "limit": 3}' | python3 -m json.tool
```

**Hit a boundary you set.**

```bash
curl -s -X POST localhost:8090/v1/models/retail/query "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["total_sales"],"dimensions":["store.s_city"]}'
```

```
{"error":"dimension \"store.s_city\": field is not a declared dimension"}
```

You did not declare `s_city` a dimension in Edit 3, so nobody can group by it.

## Stage 8. Governance

**Goal.** Show that access rules are enforced by the compiler and not by good behaviour. A
caller who is not allowed gets refused before any SQL exists.

**What happens.** You request a personal-data column as `analyst` and get a 403, with no SQL
produced. You request the same data as `tx_analyst` and see the compiler add a `WHERE` that
limits rows to Texas. Then you try to claim `admin` through the gateway's analyst path. The
gateway overwrites the role header, so the claim has no effect. This is why the server must
sit behind a proxy that sets identity in header mode.


**A denied column is refused before SQL exists.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8090/v1/models/retail/sql "${H[@]}" \
  -H 'Content-Type: application/json' -d '{"metrics":["total_sales"],"dimensions":["customer.c_last_name"]}'
```

`403` comes back from the `/sql` endpoint, which only compiles. There is no SQL to leak.
The rule came from a PII tag in DataHub. Send the same request with
`X-Semantic-Role: admin` and you get `200` and the SQL, because `admin` has no denied fields.

**A row filter scopes the answer to the caller.**

```bash
curl -s -X POST localhost:8090/v1/models/retail/query -H 'X-Semantic-User: me' -H 'X-Semantic-Role: tx_analyst' \
  -H 'Content-Type: application/json' -d '{"metrics":["total_sales"],"dimensions":["store.s_state"]}'
```

Only Texas comes back. The request asked for every state. Look at the SQL for the same
request as `tx_analyst` to see the `WHERE` the compiler added.

**The gateway decides the role, not the caller.** The chat path goes through an nginx
gateway with one path per role. Try to claim `admin` through the analyst path.

```bash
kubectl -n chat port-forward svc/semantic-gateway 8091:8080 &
curl -s -X POST localhost:8091/analyst/v1/models/retail/query \
  -H 'X-Semantic-Role: admin' -H 'Content-Type: application/json' \
  -d '{"metrics":["total_sales"],"dimensions":["customer.c_last_name"]}'
```

The gateway overwrote the header, so the request ran as `analyst` and was refused. Read
`chat/gateway.yaml` to see how. Without a proxy like this, header mode trusts anyone. That is
why production uses `server.auth.mode: jwt`.

## Stage 9. Change the model, the catalog, and the schema

**Goal.** Learn that a semantic layer is maintained over time. Three different things change
in real life, and each one reaches production by a different route.

**What happens.** A metric edit changes the model version on apply. A catalog change shows up
in a new draft but never in the published model until a person copies it over. A schema change
in Trino is caught by the drift check, so the server keeps serving the last good version while
the operator flags the problem. You cause each one and watch the result.


A semantic layer is maintained, not written once. Try three kinds of change.

**Change a metric.** In `work/semanticmodel.yaml`, change the `total_profit` description,
then apply.

```bash
kubectl apply -f work/semanticmodel.yaml
kubectl -n semantic-system get semanticmodel retail
```

`VERSION` changes. The plan cache keys on the version, so no request is answered from the old
definition.

**Change the catalog.** In DataHub, open `item`, then the `i_class` column. Add the glossary
term **Product Category**, or create a new term. Re-derive in the toolbox and compare.

```bash
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -enrich datahub -datahub-platform trino -datahub-dataset-prefix iceberg \
  -model retail -name retail -out scaffold-datahub-v2.yaml
diff scaffold-datahub.yaml scaffold-datahub-v2.yaml
```

The new synonym is in the new draft and not in your published model. Catalog changes do not
flow into production by themselves. A person reviews them and carries them over. That review
is what "certified" means.

**Break the schema.** Rename a column the model uses.

```bash
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'ALTER TABLE iceberg.osi_demo.item RENAME COLUMN i_brand TO i_brand_name'
kubectl -n semantic-system get semanticmodel retail -w
```

Within a minute `DRIFT` becomes `True`.

```bash
kubectl -n semantic-system get semanticmodel retail \
  -o jsonpath='{.status.conditions[?(@.type=="DriftDetected")].message}{"\n"}'
```

```
item: missing columns: i_brand (column i_brand)
```

The server keeps serving the last published version, so other queries still work. A new
version of the model would not publish until the drift is fixed. Fix it.

```bash
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'ALTER TABLE iceberg.osi_demo.item RENAME COLUMN i_brand_name TO i_brand'
```

`DRIFT` returns to `False` on the next check.

## Stage 10. Chat with your data

**Goal.** Put an LLM on top of the layer and see why it cannot make the mistakes from Stage 1.
The LLM picks from a published vocabulary and never writes SQL.

**What happens.** Open WebUI sends your question to a model on OpenRouter. The model sees the
tools the semantic server offers over MCP, such as listing metrics and querying them. It calls
those tools with metric and dimension names. The request passes through the gateway, which
sets the role, then the server plans and runs the SQL. You expand each tool call to see this,
and you try a forbidden question to see the refusal.


Now put an LLM in front of the model. Open WebUI talks to OpenRouter for the model and to the
semantic server over MCP for the data.

**The tools the server offers.** The MCP endpoint exposes four tools. None of them takes plain
English. The LLM turns English into a structured request, and the server does the rest.

| Tool | What it does |
|---|---|
| `list_models` | Lists the published semantic models. |
| `list_metrics` | Lists the certified metrics with their descriptions and synonyms. |
| `list_dimensions` | Lists the declared group-by fields, as `dataset.field`, with types and synonyms. |
| `query_metric` | Takes metrics, dimensions, filters, a time grain, ordering, and a limit. Compiles one SQL statement, runs it on Trino, and returns the rows plus the SQL. |

The description of `query_metric` tells the model not to write SQL. The server would not
accept SQL anyway, because the tool has no field for it.

**Configure the LLM.** Store your OpenRouter key in a Secret and choose a model that supports
tool calling.

```bash
kubectl -n chat create secret generic openrouter --from-literal=OPENAI_API_KEY=sk-or-...
kubectl -n chat patch configmap open-webui --type merge \
  -p '{"data":{"DEFAULT_MODELS":"anthropic/claude-sonnet-4.5"}}'
kubectl -n chat rollout restart deploy/open-webui
kubectl -n chat rollout status deploy/open-webui
```

Change the model the same way at any time. `kubectl -n chat get configmap open-webui -o yaml`
shows every setting. The environment is the source of truth on each restart.

**Connect the semantic layer.** Open <http://localhost:3000>. Close the What's New dialog.
Open the user menu, then **Admin Panel**, then **Settings**, then **Integrations**. Under
**External Tool Servers**, click **Add Connection**. The Type button starts as **OpenAPI**.
Click it once to switch to **MCP Streamable HTTP**.

| Setting | Value |
|---|---|
| Type | MCP Streamable HTTP |
| URL | `http://semantic-gateway.chat.svc.cluster.local:8080/analyst/mcp` |
| Auth | None |
| Name | `retail (analyst)` |

The URL is the gateway's analyst path, so this chat runs as `analyst`. Add a second
connection with `/tx_analyst/mcp` to chat as the Texas-only role. Connections added in the UI
last until the Open WebUI pod restarts.

**Let the model call tools.** In a new chat, select your model. Click **Model controls** at
the top of the chat, open **Advanced Params**, and set **Function Calling** to **Native**.
Enable the `retail (analyst)` tool for the chat with the **Integrations** button under the
message box.

**Ask questions.** Start with these.

- What can I analyze here? Which metrics and dimensions are there?
- What is revenue per employee in each state?
- Which product categories had the most revenue in 2002?
- Show me revenue by customer last name.

Expand each tool call in the answer. You will see the model call `list_metrics` or
`list_dimensions`, then `query_metric` with a JSON request like the ones you sent with `curl`.
The response carries the SQL the server compiled.

That is what "the LLM never writes SQL" means. The LLM chooses `store_productivity` and
`store.s_state` from the vocabulary you published. It matched "revenue per employee" because
you wrote that synonym. The SQL comes from the planner, from your definition, under the role
the gateway set. The fourth question is refused, because a DataHub PII tag became a rule.

### What happens, step by step

Follow one question, "What is revenue per employee in each state?", from your keyboard to the
answer. Each step says who does the work.

1. **You type the question in Open WebUI.** Open WebUI sends it to the model on OpenRouter,
   together with the list of tools from the MCP connection. *Who: Open WebUI.*
2. **The model asks what it can use.** It calls `list_metrics` and `list_dimensions`. The
   request goes to the gateway, which sets your role to `analyst` from the URL path, and then
   to the semantic server. The server answers from the published model. *Who: the server.*
3. **The model matches your words to names.** "Revenue per employee" matches the synonym of
   `store_productivity`. "In each state" matches the dimension `store.s_state`. This is the
   only place where language is interpreted. *Who: the model.*
4. **The model calls `query_metric`** with a structured request. *Who: the model.*

   ```json
   {"metrics": ["store_productivity"], "dimensions": ["store.s_state"]}
   ```

5. **The server checks the request against the role.** Every metric and dimension must exist,
   be allowed for `analyst`, and not be a denied field. If one fails, the server returns an
   error here and no SQL exists. *Who: the server.*
6. **The server plans the SQL.** It uses the join tree, the primary keys, and the metric
   definitions you wrote in Stage 5. It adds any row filter the role has. The result is one
   statement that counts each store's headcount once. The same request, model version, and
   role always give the same text. *Who: the server, with no LLM involved.*
7. **The server runs the SQL on Trino** as the `semantic-server` user, which can only read.
   *Who: the server.*
8. **The server returns the result.** The tool result holds the columns, the rows, and the SQL
   it ran. The SQL is there for provenance and the model cannot change it. *Who: the server.*
9. **The model writes the answer.** It reads the rows and replies in plain English, for
   example "Tennessee is about 644,567 per employee and Texas is about 1,826,350". The numbers
   come from Trino. *Who: the model.*

The operator's manager takes no part in any of this. It finished its work in Stage 6 when it
published the model, and it keeps checking for drift in the background.

Now try the question the role may not ask, "Show me revenue by customer last name". The model
goes through steps 1 to 4 as before. At step 5 the server finds `customer.c_last_name` in the
denied fields, which came from a PII tag in DataHub, and returns an error. The model has no
SQL to run and no rows to show, so it can only tell you it was refused.

Switch the tool to `retail (tx_analyst)` and ask the second question again. Only Texas comes
back, and the model cannot talk its way past it.

## Reset and tear down

Remove the model, which also drops its views.

```bash
kubectl delete -f work/semanticmodel.yaml
```

Remove the operator, to practise Stage 3 again.

```bash
helm uninstall semantic-operator -n semantic-system
```

Remove everything.

```bash
make down
```

Your files in `work/` stay on disk.

## Troubleshooting

**`make up` stops at DataHub.** DataHub is the largest component. Check memory with
`docker stats` and the pods with `kubectl -n datahub get pods`. The `datahub-system-update`
job prepares OpenSearch and Postgres and must finish before GMS starts. Run `make datahub`
again.

**`ossiectl derive -enrich datahub` matched 0 tables.** The URN it built does not match
DataHub. The error prints the URN it tried. Compare it with the URN on the dataset page.

**The model stays `PUBLISHED=False`.** Read the conditions as in Stage 6 and the manager log
with `kubectl -n semantic-system logs deploy/semantic-operator-manager`.

**The chat answers without calling tools.** Function Calling is not set to Native, the tool
is not enabled in the chat, or the model does not support tool calling on OpenRouter.

**Another namespace can reach the semantic server.** kindnet could not program its nftables
rules, so NetworkPolicy is not enforced. Check with
`kubectl -n kube-system logs -l app=kindnet | grep -A2 'syncing nftables rules'`. An error
there means the host kernel lacks nftables support. The lab still works. Only the network
lockdown is missing.

**Open WebUI cannot reach the MCP server.** Check that the gateway answers from inside the
cluster.

```bash
kubectl -n lab exec deploy/toolbox -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://semantic-gateway.chat.svc.cluster.local:8080/analyst/v1/models').read()[:200])"
```
