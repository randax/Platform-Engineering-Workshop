# demo-app — built in-cluster from source by the app-team golden path.
#
# Multi-stage: a golang builder compiles a static binary; the runtime is scratch
# + a CA bundle (copied from the builder). Go deps are VENDORED, so the build
# needs no module proxy.
#
# OFFLINE RULE: an in-cluster build pod can't reach the internet — only Zot
# (in-cluster). So the builder base is pulled FROM your own Zot registry, seeded
# the same way module 07 seeds busybox:
#   crane copy --insecure public.ecr.aws/docker/library/golang:1.25-alpine \
#     localhost:30500/library/golang:1.25-alpine
FROM zot.zot.svc.cluster.local:5000/library/golang:1.25-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -mod=vendor -o /demo-app .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /demo-app /demo-app
EXPOSE 8080
ENTRYPOINT ["/demo-app"]
