# demo-app — built in-cluster from source by the app-team golden path.
#
# Multi-stage: a golang builder compiles a static binary; the runtime is scratch
# + a CA bundle (copied from the builder). Go deps are VENDORED, so the build
# needs no module proxy.
#
# OFFLINE RULE: an in-cluster build pod can't reach the internet — only Zot
# (in-cluster). So the builder base is pulled FROM your own Zot registry, seeded
# the same way module 07 seeds busybox — on docker/kind from the local mirror,
# offline:
#   crane copy --insecure localhost:5001/docker/library/golang:1.25-alpine \
#     zot.cloudbox.k8s.test/library/golang:1.25-alpine
# On tbx the same warmed bytes are served by tbxd's catch-all port in its
# path form, `<gateway>:5059/public.ecr.aws/docker/library/golang:1.25-alpine`
# (the :5055 listener is docker.io-only) — see the module 08 README.
# The base is on the pre-pull list (scripts/images.txt) since the adventure
# refresh (issue #193): door 1 made in-cluster Go builds a first-class path, so
# every attendee pays the ~59 MB once, at home. Pre-refresh pulls can still
# seed from public.ecr.aws online.
FROM zot.zot.svc.cluster.local:5000/library/golang:1.25-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -mod=vendor -o /demo-app .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /demo-app /demo-app
EXPOSE 8080
ENTRYPOINT ["/demo-app"]
