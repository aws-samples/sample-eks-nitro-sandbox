# Build the Argo Rollouts canary step plugin, and ship it in an image whose only
# job is to hand the binary to the controller pod.
#
# The build runs in a container, so this sample needs no Go toolchain on your
# machine. scripts/register-step-plugin.sh builds this image, pushes it to a
# repository your cluster can pull from, and runs it as an initContainer that
# copies the binary into a volume the Argo Rollouts controller reads.

FROM public.ecr.aws/docker/library/golang:1.26 AS build

# The architecture of the node the Argo Rollouts controller runs on, NOT of the
# machine doing the build, so a build on an arm64 laptop still produces a binary
# the controller can exec. register-step-plugin.sh reads it off the controller's
# own node and passes it in.
ARG TARGETARCH=amd64

# Go's defaults, left in place so the module proxy and the checksum database
# verify every dependency. Override them only on a network that cannot reach
# proxy.golang.org, where `--build-arg GOPROXY=direct --build-arg GOSUMDB=off`
# fetches straight from the source repositories instead; the committed go.sum
# still verifies every module by hash either way.
ARG GOPROXY=https://proxy.golang.org,direct
ARG GOSUMDB=sum.golang.org

# argo-rollouts v1.10.1 needs go >= 1.26.1 and this image is golang:1.26, so
# GOTOOLCHAIN=local builds with the image's toolchain rather than downloading one.
ENV GOPROXY=${GOPROXY} \
    GOSUMDB=${GOSUMDB} \
    GOTOOLCHAIN=local \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=${TARGETARCH}

WORKDIR /src

# The module graph first, so it caches independently of source edits. go.sum is
# committed and the default -mod=readonly proves it is complete: a missing hash
# fails the build rather than being rewritten silently.
COPY go.mod go.sum ./
RUN go mod download

COPY main.go plugin.go ./
RUN go build -trimpath -ldflags="-s -w" -o /bin/sandbox-warmpool-stepplugin . \
    && go version -m /bin/sandbox-warmpool-stepplugin | grep -E 'argo-rollouts|go-plugin' \
    && echo "built: $(sha256sum /bin/sandbox-warmpool-stepplugin)"

# The base is busybox rather than scratch precisely so `cp` exists: the
# initContainer that stages the binary is this image running `cp`. The plugin
# binary itself is static and self-contained.
FROM public.ecr.aws/docker/library/busybox:1.36
COPY --from=build /bin/sandbox-warmpool-stepplugin /bin/sandbox-warmpool-stepplugin
ENTRYPOINT ["/bin/sandbox-warmpool-stepplugin"]
