# Build the imogen tool server.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /imogen-toolserver ./cmd/imogen-toolserver
RUN CGO_ENABLED=0 go build -trimpath -o /imogen-aoai-proxy ./cmd/imogen-aoai-proxy

# Runtime image. The tool server shells out to az (gallery and build actions)
# and kubectl (image validation on the builder cluster), so the in-cluster image
# bundles both, unlike the earlier distroless build. The azure-cli base ships az,
# bash and jq on Azure Linux; we add kubectl and the validation scripts.
FROM mcr.microsoft.com/azure-cli:latest

ARG KUBECTL_VERSION=v1.34.8
RUN tdnf install -y ca-certificates curl tar gawk gzip && tdnf clean all && \
    arch="$(uname -m)"; \
    case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac; \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" && \
    chmod +x /usr/local/bin/kubectl && \
    kubectl version --client

WORKDIR /app
COPY hack ./hack
COPY deploy ./deploy
COPY --from=build /imogen-toolserver /usr/local/bin/imogen-toolserver
COPY --from=build /imogen-aoai-proxy /usr/local/bin/imogen-aoai-proxy

ENV IMOGEN_TOOLSERVER_ADDR=:8080 \
    IMOGEN_IN_CLUSTER=1
EXPOSE 8080
ENTRYPOINT ["/app/hack/toolserver-entrypoint.sh"]
