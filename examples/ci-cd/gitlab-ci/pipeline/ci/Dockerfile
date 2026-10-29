# A two-stage build, so the privileged job does real work: compile in one image, ship the
# binary on another. Both stages run on the Docker daemon the job pod started inside its own
# sandbox.
FROM public.ecr.aws/docker/library/golang:1.27.2-alpine3.24 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /hello main.go

FROM public.ecr.aws/docker/library/alpine:3.24.3
COPY --from=build /hello /hello
ENTRYPOINT ["/hello"]
