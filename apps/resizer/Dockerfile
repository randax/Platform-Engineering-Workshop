# Resizer — multi-stage build to a static binary in an empty image.

FROM golang:1.25-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/resizer .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/resizer /resizer
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/resizer"]
