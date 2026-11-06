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

FROM python:3.12-slim
# acryl-datahub[trino] minus one piece: the extra asks for sqlglot[c], whose
# compiled accelerator ships only as a source package that fails to build.
# Plain sqlglot is the same parser without the speed-up.
RUN pip install --no-cache-dir 'acryl-datahub==1.6.0' 'sqlglot==30.8.0' \
      'trino[sqlalchemy]>=0.308,<=0.336.0' 'sqlalchemy>=1.4.39,<2' 'numpy<2' \
      'acryl-datahub-classify==0.0.11' 'cachetools<6' 'greenlet<4' 'patchy==2.8.0' \
      'schwifty<2026' 'sqlparse<0.6' 'pyyaml>=6'
COPY --from=ossiectl /out/ossiectl /usr/local/bin/ossiectl
WORKDIR /work
CMD ["sleep", "infinity"]
