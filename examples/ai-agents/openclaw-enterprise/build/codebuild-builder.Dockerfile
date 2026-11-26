FROM public.ecr.aws/docker/library/alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

ENV DOCKER_HOST=unix:///var/run/docker.sock

# Keep the privileged builder purpose-built. These are the only host tools
# called by the buildspec and build-images.sh.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        aws-cli \
        bash \
        coreutils \
        docker \
        docker-cli-buildx \
        git \
        nodejs \
        python3 \
    && for command in aws bash docker git node python3 sha256sum; do \
        command -v "$command"; \
    done \
    && dockerd --version \
    && docker buildx version
