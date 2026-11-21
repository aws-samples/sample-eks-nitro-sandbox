FROM public.ecr.aws/codebuild/amazonlinux-x86_64-standard@sha256:4b98f5054863c6f18a3049d5ccebbfc6d34b6b5cf37152fb8bb50af81c390660

# The sample does not use the legacy ECS CLI bundled in this builder. Remove it
# so Inspector evaluates only the tools available to the privileged build.
RUN test -x /usr/local/bin/ecs-cli \
    && rm /usr/local/bin/ecs-cli
