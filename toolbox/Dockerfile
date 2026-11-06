# The lab toolbox: the workstation you exec into.
#   ossiectl   Semantic Operator's CLI (derive, validate, unwrap, wrap),
#              installed from upstream at the commit the lab pins
#   datahub    DataHub's CLI and ingestion framework, with the Trino source
#
#   docker build --build-arg OPERATOR_REF=<commit> -t semantic-lab/toolbox:dev toolbox/
FROM golang:1.26 AS ossiectl
ARG OPERATOR_REF
RUN test -n "$OPERATOR_REF" && \
    CGO_ENABLED=0 GOBIN=/out go install -ldflags "-s -w" \
      github.com/kubeflow/semantic-operator/cmd/ossiectl@${OPERATOR_REF}

FROM python:3.13-slim
# The DataHub CLI with its Trino source. 1.7.0.19 is the newest stable release
# on PyPI. It talks to the v1.8.0 server the lab runs.
RUN pip install --no-cache-dir 'acryl-datahub[trino]==1.7.0.19' 'pyyaml>=6'
COPY --from=ossiectl /out/ossiectl /usr/local/bin/ossiectl
WORKDIR /work
CMD ["sleep", "infinity"]
