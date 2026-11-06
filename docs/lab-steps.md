# Lab steps at a glance

This is the short version of the [Hands-on lab with DataHub and Trino](lab-guide.md).
Each step lists what to run and what it does. Read the full guide when you want the why and
the expected output.

Three terminals help.

| Terminal | Where | Used for |
|---|---|---|
| **A** | lab directory, on your machine | `make`, `kubectl apply` |
| **B** | lab directory, a second shell | building images, `helm`, `curl` |
| **T** | inside the toolbox pod | `ossiectl` |

## Part 1. Build the starting point

**Step 1. Create the lab.** *(A)*
Builds kind, Trino with the retail data, DataHub with metadata, the toolbox, and the chat UI. No operator yet.

```bash
git clone https://github.com/tarekabouzeid/kf-semantic-operator-lab
cd kf-semantic-operator-lab
make up
```

**Step 2. Check it is up.** *(A)*
Every pod is `Running` or `Completed`, and `semantic-system` is empty.

```bash
make status
```

Open DataHub at <http://localhost:9002> (`datahub` / `datahub`), Trino at
<http://localhost:8080>, and Open WebUI at <http://localhost:3000>.

## Part 2. Understand the inputs

**Step 3. Explore the raw tables.** *(A)*
Opens the Trino CLI on the five tables in `iceberg.osi_demo`.

```bash
kubectl -n lakehouse exec -it deploy/trino -- trino --catalog iceberg --schema osi_demo
```

```sql
SHOW TABLES;
DESCRIBE store_sales;
```

**Step 4. Run the naive query.** *(A, Trino CLI)*
Shows SQL that runs and looks right but double counts headcount. Note the two numbers.

```sql
SELECT s.s_state, sum(ss.ss_ext_sales_price) / sum(s.s_number_employees)
FROM store_sales ss JOIN store s ON s.s_store_sk = ss.ss_store_sk
GROUP BY 1 ORDER BY 1;
```

**Step 5. Read the business meaning in DataHub.** *(browser)*
Open `store_sales`, `store`, and `customer` on the Trino platform. Note the column
descriptions, the glossary terms such as **Revenue**, and the **PII** tags.

**Step 6. Open the toolbox.** *(T)*
This is your workstation for the rest of the lab. `/work` is the lab's `work/` folder on your machine.

```bash
kubectl -n lab exec -it deploy/toolbox -- bash
env | grep -E 'ENGINE|DATAHUB|SQL_DIALECT' | sort
```

## Part 3. Install Semantic Operator

**Step 7. Get the operator source.** *(B)*
No tagged release exists yet, so clone Semantic Operator at the commit the lab is tested with.

```bash
git clone https://github.com/kubeflow/semantic-operator
git -C semantic-operator checkout 4fd7057ef3a67b3711a927e639e6a78550d6c945
```

**Step 7b. Build and load the images.** *(B)*
Builds the operator (manager) and the query server and loads them into kind.

```bash
docker build --target manager -t semantic-lab/manager:dev semantic-operator
docker build --target server  -t semantic-lab/server:dev  semantic-operator
kind load docker-image semantic-lab/manager:dev semantic-lab/server:dev --name semantic-lab
```

**Step 8. Read the Helm values.** *(B)*
Points the operator at Trino, uses header auth behind the gateway, and opens the network policy to `chat` and `lab`.

```bash
cat operator/values.yaml
```

**Step 9. Install.** *(B)*
Creates the `SemanticModel` CRD, the manager, and the server in `semantic-system`.

```bash
helm install semantic-operator semantic-operator/charts/semantic-operator \
  --namespace semantic-system --create-namespace \
  -f operator/values.yaml --wait
```

**Step 10. Check the install.** *(B)*
Both pods run. No models exist yet.

```bash
kubectl -n semantic-system get pods
kubectl get semanticmodels -A
kubectl explain semanticmodel.spec
```

## Part 4. Write the model

**Step 11. Derive from Trino only.** *(T)*
Writes the physical half of an Apache Ossie model from the engine schema.

```bash
cd /work
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -model retail -name retail -out scaffold.yaml
```

**Step 12. Derive from Trino plus DataHub.** *(T)*
Same model, plus descriptions, synonyms from glossary terms, and denied PII columns.

```bash
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -enrich datahub -datahub-platform trino -datahub-dataset-prefix iceberg \
  -model retail -name retail -out scaffold-datahub.yaml
```

**Step 13. Compare the two drafts.** *(T)*
Shows exactly what DataHub added, and the TODOs that only a person can fill.

```bash
diff scaffold.yaml scaffold-datahub.yaml | grep '^>'
grep -n 'TODO' scaffold-datahub.yaml
```

**Step 14. Start your model.** *(T)*
Your copy to edit. Open it in your own editor at `work/semanticmodel.yaml`.

```bash
cp scaffold-datahub.yaml semanticmodel.yaml
```

**Step 15. Certify it.** *(editor)*
Make the seven edits in the full guide. Run `ossiectl validate -f semanticmodel.yaml` *(T)* after each one.

| Edit | What you add |
|---|---|
| 1 | Model description, `ai_context`, and `viewDatabase: iceberg.semantic_views` |
| 2 | Primary keys on all five datasets |
| 3 | `dimension: {}` on the nine fields people may group by |
| 4 | The four real joins. Drop the backwards one and add the missing date join |
| 5 | Metrics `total_sales`, `total_profit`, `transaction_count`, `store_productivity` |
| 6 | Roles `tx_analyst` with a Texas row filter, and `admin` |
| 7 | One governed view, `revenue_by_state` |

**Step 16. Validate and inspect the Ossie part.** *(T)*
Confirms the model is valid offline and prints the portable Apache Ossie document.

```bash
ossiectl validate -f semanticmodel.yaml
ossiectl unwrap -f semanticmodel.yaml | head -20
```

## Part 5. Publish and query

**Step 17. Apply the model.** *(A)*
The operator validates, compiles, checks drift against Trino, publishes, and creates the view.

```bash
kubectl apply -f work/semanticmodel.yaml
kubectl -n semantic-system get semanticmodels -w
```

**Step 18. Read what the operator did.** *(A)*
Shows the five conditions, the published artifact, and the view in Trino.

```bash
kubectl -n semantic-system get semanticmodel retail \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl -n semantic-system get configmap sm-retail-compiled --show-labels
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'SHOW CREATE VIEW iceberg.semantic_views.revenue_by_state'
```

**Step 19. Connect to the server.** *(B)*
Forwards the server port and sets the headers for the `analyst` role.

```bash
kubectl -n semantic-system port-forward svc/semantic-operator-server 8090:8090 &
H=(-H 'X-Semantic-User: me' -H 'X-Semantic-Role: analyst')
```

**Step 20. Discover the vocabulary.** *(B)*
Lists what an agent sees: models, metrics, and dimensions with their descriptions and synonyms.

```bash
curl -s localhost:8090/v1/models/retail/metrics "${H[@]}" | python3 -m json.tool
curl -s localhost:8090/v1/models/retail/dimensions "${H[@]}" | python3 -m json.tool
```

**Step 21. Ask the Step 4 question correctly.** *(B)*
Returns the certified answer. Compare it with the naive numbers.

```bash
curl -s -X POST localhost:8090/v1/models/retail/query "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["store_productivity","total_sales"],"dimensions":["store.s_state"]}' | python3 -m json.tool
```

**Step 22. Read the generated SQL.** *(B)*
Compiles without running. Run it twice and the SQL is identical.

```bash
curl -s -X POST localhost:8090/v1/models/retail/sql "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["store_productivity"],"dimensions":["store.s_state"]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan"]["sql"])'
```

**Step 23. Filter, sort, and limit.** *(B)*
Top three categories by revenue in 2002.

```bash
curl -s -X POST localhost:8090/v1/models/retail/query "${H[@]}" -H 'Content-Type: application/json' -d '{
  "metrics": ["total_sales"], "dimensions": ["item.i_category"],
  "filters": [{"field": "date_dim.d_year", "op": "=", "value": 2002}],
  "orderBy": [{"field": "total_sales", "direction": "desc"}], "limit": 3}' | python3 -m json.tool
```

## Part 6. Governance and change

**Step 24. Get refused on PII.** *(B)*
`403` before any SQL exists, because DataHub tagged the column PII.

```bash
curl -s -X POST localhost:8090/v1/models/retail/sql "${H[@]}" -H 'Content-Type: application/json' \
  -d '{"metrics":["total_sales"],"dimensions":["customer.c_last_name"]}'
```

**Step 25. See a row filter.** *(B)*
The `tx_analyst` role gets only Texas for the same request.

```bash
curl -s -X POST localhost:8090/v1/models/retail/query -H 'X-Semantic-User: me' -H 'X-Semantic-Role: tx_analyst' \
  -H 'Content-Type: application/json' -d '{"metrics":["total_sales"],"dimensions":["store.s_state"]}'
```

**Step 26. Try to spoof a role.** *(B)*
The gateway overwrites the role header, so claiming `admin` on the analyst path still fails.

```bash
kubectl -n chat port-forward svc/semantic-gateway 8091:8080 &
curl -s -X POST localhost:8091/analyst/v1/models/retail/query -H 'X-Semantic-Role: admin' \
  -H 'Content-Type: application/json' -d '{"metrics":["total_sales"],"dimensions":["customer.c_last_name"]}'
```

**Step 27. Publish a new version.** *(A)*
Edit any metric description in `work/semanticmodel.yaml`. `VERSION` changes on apply.

```bash
kubectl apply -f work/semanticmodel.yaml
kubectl -n semantic-system get semanticmodel retail
```

**Step 28. Pick up a catalog change.** *(browser, then T)*
Add a glossary term to a column in DataHub, re-derive, and diff. Nothing reaches production until you copy it into your model.

```bash
ossiectl derive -source engine -catalog iceberg -database osi_demo \
  -enrich datahub -datahub-platform trino -datahub-dataset-prefix iceberg \
  -model retail -name retail -out scaffold-datahub-v2.yaml
diff scaffold-datahub.yaml scaffold-datahub-v2.yaml
```

**Step 29. Cause drift and fix it.** *(A)*
Renaming a column the model uses sets `DRIFT=True` within a minute. Queries keep working on the last published version.

```bash
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'ALTER TABLE iceberg.osi_demo.item RENAME COLUMN i_brand TO i_brand_name'
kubectl -n semantic-system get semanticmodel retail -w
kubectl -n lakehouse exec deploy/trino -- trino --execute \
  'ALTER TABLE iceberg.osi_demo.item RENAME COLUMN i_brand_name TO i_brand'
```

## Part 7. Chat with your data

**Step 30. Configure the LLM.** *(A)*
Stores your OpenRouter key and picks a model that supports tool calling.

```bash
kubectl -n chat create secret generic openrouter --from-literal=OPENAI_API_KEY=sk-or-...
kubectl -n chat patch configmap open-webui --type merge \
  -p '{"data":{"DEFAULT_MODELS":"<openrouter-model-id>"}}'
kubectl -n chat rollout restart deploy/open-webui
```

**Step 31. Connect the semantic layer.** *(browser)*
In Open WebUI, open **Admin Panel**, then **Settings**, then **External Tools**. Add an
**MCP (Streamable HTTP)** connection with no auth to
`http://semantic-gateway.chat.svc.cluster.local:8080/analyst/mcp`.

**Step 32. Allow tool calls.** *(browser)*
In a chat, set **Chat Controls**, then **Advanced Params**, then **Function Calling** to
**Native**, and enable the tool with the tools button.

**Step 33. Ask and inspect.** *(browser)*
Ask these questions and expand each tool call. The LLM picks metric names. The server writes the SQL.

- What can I analyze here?
- What is revenue per employee in each state?
- Which product categories had the most revenue in 2002?
- Show me revenue by customer last name.

**Step 34. Chat as another role.** *(browser)*
Add a second connection on `/tx_analyst/mcp` and ask the state question again. Only Texas comes back.

## Part 8. Finish

**Step 35. Compare with the reference.** *(A)*
Shows what you did differently from the finished model.

```bash
diff work/semanticmodel.yaml model/semanticmodel.yaml
```

**Step 36. Reset or tear down.** *(A)*
Remove the model, remove the operator to practise again, or delete everything. `work/` stays.

```bash
kubectl delete -f work/semanticmodel.yaml
helm uninstall semantic-operator -n semantic-system
make down
```
