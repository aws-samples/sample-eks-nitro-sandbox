ARG OWNERSHIP_HELPER_BUILDER_IMAGE=docker.io/library/golang:1.25.4-alpine3.22@sha256:d3f0cf7723f3429e3f9ed846243970b20a2de7bae6a5b66fc5914e228d831bbb
FROM ${OWNERSHIP_HELPER_BUILDER_IMAGE} AS builder
WORKDIR /src
COPY main.go main_test.go ./
RUN go test ./... && \
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags="-s -w" -o /ownership-helper main.go

FROM scratch
COPY --from=builder /ownership-helper /ownership-helper
ENTRYPOINT ["/ownership-helper"]
