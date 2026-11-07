"""Optional shortcut for Stage 5: apply the seven certification edits to a draft.

The guide has you make these edits by hand so you learn what each one decides.
This script makes the same seven edits to your own draft, so you can skip the
typing. It reads the draft that `ossiectl derive -enrich datahub` wrote and
writes a new file. It never changes the draft and it never replaces a file that
already exists unless you pass --force.

Run it from the lab directory on your machine. The toolbox pod has PyYAML.

  kubectl -n lab exec -i deploy/toolbox -- python - \
    /work/scaffold-datahub.yaml /work/semanticmodel.auto.yaml < model/certify.py

Comments in the draft are not kept, because PyYAML drops them.
"""
import os
import sys

import yaml

PRIMARY_KEYS = {
    "customer": ["c_customer_sk"],
    "date_dim": ["d_date_sk"],
    "item": ["i_item_sk"],
    "store": ["s_store_sk"],
    "store_sales": ["ss_item_sk", "ss_ticket_number"],
}

DIMENSIONS = {
    "store": ["s_state", "s_store_name"],
    "item": ["i_category", "i_brand"],
    "date_dim": ["d_year", "d_month_name"],
    "customer": ["c_birth_country", "c_preferred_cust_flag", "c_last_name"],
}

RELATIONSHIPS = [
    ("store_sales_to_customer", "customer", "ss_customer_sk", "c_customer_sk"),
    ("store_sales_to_date_dim", "date_dim", "ss_sold_date_sk", "d_date_sk"),
    ("store_sales_to_item", "item", "ss_item_sk", "i_item_sk"),
    ("store_sales_to_store", "store", "ss_store_sk", "s_store_sk"),
]


def metric(name, expr, desc, synonyms):
    return {
        "name": name,
        "expression": {"dialects": [{"dialect": "ANSI_SQL", "expression": expr}]},
        "description": desc,
        "ai_context": {"synonyms": synonyms},
    }


METRICS = [
    metric("total_sales", "SUM(store_sales.ss_ext_sales_price)",
           "Revenue: sales after discounts, before tax.", ["revenue", "sales"]),
    metric("total_profit", "SUM(store_sales.ss_net_profit)",
           "Net profit.", ["profit"]),
    metric("transaction_count", "COUNT(DISTINCT store_sales.ss_ticket_number)",
           "Number of sales tickets (checkouts).", ["transactions", "tickets", "orders"]),
    metric("store_productivity",
           "SUM(store_sales.ss_ext_sales_price) / NULLIF(SUM(store.s_number_employees), 0)",
           "Revenue per employee, each store's headcount counted once.",
           ["revenue per employee", "sales per employee"]),
]


def certify(doc):
    spec = doc["spec"]
    ossie = spec["ossie"]

    # Edit 1. Describe the model and point views at Iceberg.
    spec["connection"]["viewDatabase"] = "iceberg.semantic_views"
    ossie["description"] = ("Retail store sales: revenue, profit, transactions, "
                            "and store productivity.")
    ossie["ai_context"] = {"instructions": (
        "Use the certified metrics. Never compute store productivity from raw "
        "columns: headcount must be counted once per store.")}

    datasets = {d["name"]: d for d in ossie["datasets"]}
    for name in list(PRIMARY_KEYS) + list(DIMENSIONS):
        if name not in datasets:
            sys.exit(f"error: the draft has no dataset {name!r}. Is it the retail draft?")

    # Edit 2. Primary keys.
    for name, key in PRIMARY_KEYS.items():
        datasets[name]["primary_key"] = key

    # Edit 3. Dimensions. Fields the tool already marked as time stay as they are.
    for name, fields in DIMENSIONS.items():
        by_name = {f["name"]: f for f in datasets[name]["fields"]}
        for field in fields:
            if field not in by_name:
                sys.exit(f"error: dataset {name!r} has no field {field!r}")
            by_name[field].setdefault("dimension", {})

    # Edit 4. The four real joins. The backwards one is left out.
    ossie["relationships"] = [
        {"name": n, "from": "store_sales", "to": to,
         "from_columns": [fc], "to_columns": [tc]}
        for n, to, fc, tc in RELATIONSHIPS]

    # Edit 5. Metrics.
    ossie["metrics"] = METRICS

    # Edit 6. Roles. The analyst role from DataHub stays. Add two more.
    roles = spec["governance"]["roles"]
    analyst = next(r for r in roles if r["name"] == "analyst")
    roles.append({
        "name": "tx_analyst",
        "allowMetrics": ["*"],
        "denyFields": list(analyst.get("denyFields", [])),
        "rowFilters": [{"dataset": "store", "predicate": "s_state = 'TX'"}],
    })
    roles.append({"name": "admin", "allowMetrics": ["*"]})

    # Edit 7. One governed view.
    spec["views"] = [{
        "name": "revenue_by_state",
        "metrics": ["total_sales", "store_productivity"],
        "dimensions": ["store.s_state"],
        "role": "admin",
    }]
    return doc


def main():
    args = [a for a in sys.argv[1:] if a != "--force"]
    force = "--force" in sys.argv[1:]
    if len(args) != 2:
        sys.exit("usage: certify.py DRAFT.yaml OUT.yaml [--force]")
    src, dst = args
    if os.path.exists(dst) and not force:
        sys.exit(f"error: {dst} exists. Choose another name or pass --force.")
    with open(src) as f:
        doc = yaml.safe_load(f)
    doc = certify(doc)
    with open(dst, "w") as f:
        f.write("# Written by model/certify.py from " + os.path.basename(src) + ".\n")
        yaml.safe_dump(doc, f, sort_keys=False, width=100, default_flow_style=False)
    print(f"wrote {dst}. Next: ossiectl validate -f {dst}")


main()
