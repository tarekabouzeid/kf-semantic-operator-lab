"""Seed the steward metadata in steward-metadata.yaml into DataHub.

Uses DataHub's public GraphQL API, the same calls the UI makes when a person
edits a description or attaches a term. Safe to run again: creating something
that exists is skipped, and descriptions and associations are overwritten
with the same values.

  python /seed/annotate.py /seed/steward-metadata.yaml
"""

import json
import os
import sys
import time
import urllib.request

import yaml

GMS = os.environ.get("DATAHUB_GMS_URL", "http://datahub-datahub-gms.datahub.svc.cluster.local:8080")
HEADERS = {"Content-Type": "application/json"}
if os.environ.get("DATAHUB_SYSTEM_CLIENT_SECRET"):
    HEADERS["Authorization"] = "Basic __datahub_system:" + os.environ["DATAHUB_SYSTEM_CLIENT_SECRET"]


def gql(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(GMS + "/api/graphql", data=body, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.load(resp)
    errors = out.get("errors") or []
    if errors and not all("already exists" in e.get("message", "") for e in errors):
        raise RuntimeError(f"{query.split('(')[0].strip()}: {errors}")
    return out.get("data")


def main(path):
    seed = yaml.safe_load(open(path))
    platform, prefix, env = seed["platform"], seed["dataset_prefix"], seed["env"]

    def urn(table):
        return f"urn:li:dataset:(urn:li:dataPlatform:{platform},{prefix}.{table},{env})"

    # Ingestion must have landed before there is anything to annotate.
    for table in seed["datasets"]:
        for _ in range(60):
            data = gql("query($u: String!) { dataset(urn: $u) { schemaMetadata { name } } }", {"u": urn(table)})
            if data and data["dataset"] and data["dataset"]["schemaMetadata"]:
                break
            time.sleep(5)
        else:
            sys.exit(f"dataset {urn(table)} not found in DataHub; run the ingestion first")

    node = seed["glossary"]["node"]
    print(f"glossary node {node['name']}")
    gql("mutation($i: CreateGlossaryEntityInput!) { createGlossaryNode(input: $i) }",
        {"i": {"id": node["id"], "name": node["name"], "description": node["description"]}})
    term_urn = {}
    for t in seed["glossary"]["terms"]:
        print(f"  term {t['name']}")
        gql("mutation($i: CreateGlossaryEntityInput!) { createGlossaryTerm(input: $i) }",
            {"i": {"id": t["id"], "name": t["name"], "description": t["description"],
                   "parentNode": f"urn:li:glossaryNode:{node['id']}"}})
        term_urn[t["name"]] = f"urn:li:glossaryTerm:{t['id']}"
    tag_urn = {}
    for t in seed["tags"]:
        print(f"tag {t['name']}")
        gql("mutation($i: CreateTagInput!) { createTag(input: $i) }",
            {"i": {"id": t["id"], "name": t["name"], "description": t["description"]}})
        tag_urn[t["name"]] = f"urn:li:tag:{t['id']}"

    for table, spec in seed["datasets"].items():
        u = urn(table)
        print(f"dataset {table}")
        gql("mutation($i: DescriptionUpdateInput!) { updateDescription(input: $i) }",
            {"i": {"resourceUrn": u, "description": spec["description"]}})
        for term in spec.get("terms", []):
            gql("mutation($i: TermAssociationInput!) { addTerm(input: $i) }",
                {"i": {"termUrn": term_urn[term], "resourceUrn": u}})
        for col, f in spec.get("fields", {}).items():
            sub = {"resourceUrn": u, "subResource": col, "subResourceType": "DATASET_FIELD"}
            if f.get("description"):
                gql("mutation($i: DescriptionUpdateInput!) { updateDescription(input: $i) }",
                    {"i": {**sub, "description": f["description"]}})
            for term in f.get("terms", []):
                gql("mutation($i: TermAssociationInput!) { addTerm(input: $i) }",
                    {"i": {**sub, "termUrn": term_urn[term]}})
            for tag in f.get("tags", []):
                gql("mutation($i: TagAssociationInput!) { addTag(input: $i) }",
                    {"i": {**sub, "tagUrn": tag_urn[tag]}})
    print("steward metadata seeded")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/seed/steward-metadata.yaml")
