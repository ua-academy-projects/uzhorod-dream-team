# syntax=docker/dockerfile:1
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY fetcher/go.mod fetcher/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY fetcher/ ./
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fetcher ./cmd/fetcher

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fetcher /fetcher
ENTRYPOINT ["/fetcher"]
