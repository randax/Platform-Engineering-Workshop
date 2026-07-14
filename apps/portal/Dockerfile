# Cloudbox Console — multi-stage build to a static binary in an empty image.
# Built the same way in GitHub Actions (buildx, multi-arch) and by the
# in-cluster BuildKit from module 07.

FROM golang:1.24-alpine AS build
WORKDIR /src

# Dependencies first, so BuildKit caches this layer across code changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO off → fully static binary that runs in a FROM scratch image.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/portal .

FROM scratch
# CA bundle so outbound HTTPS (the Kubernetes API) can be verified.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/portal /portal
# Non-root numeric UID — required by the restricted Pod Security Standard.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/portal"]
