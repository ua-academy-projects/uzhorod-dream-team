# syntax=docker/dockerfile:1
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY *.go ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags="-s -w" -o /fetcher .

# Static binary + CA certificates, no shell.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /fetcher /fetcher
EXPOSE 3002
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD ["/fetcher", "healthcheck"]
ENTRYPOINT ["/fetcher"]