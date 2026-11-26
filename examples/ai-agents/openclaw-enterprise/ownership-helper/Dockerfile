ARG OWNERSHIP_HELPER_BUILDER_IMAGE=public.ecr.aws/docker/library/golang:1.26.9-alpine3.23@sha256:6750308561953d451210ed1a8086d36c8c8bdcbf672d38d9d0d424b8a7a0216c
FROM ${OWNERSHIP_HELPER_BUILDER_IMAGE} AS builder
WORKDIR /src
COPY go.mod main.go main_test.go ./
RUN go test ./... && \
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags="-s -w" -o /ownership-helper main.go

FROM scratch
COPY --from=builder /ownership-helper /ownership-helper
ENTRYPOINT ["/ownership-helper"]
