FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/history ./cmd/history

FROM golang:1.26-alpine AS goose-build
RUN CGO_ENABLED=0 GOBIN=/out go install -trimpath -ldflags="-s -w" \
    -tags='no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb' \
    github.com/pressly/goose/v3/cmd/goose@v3.24.3

FROM alpine:3.24 AS migrate
RUN apk add --no-cache ca-certificates
COPY --from=goose-build /out/goose /goose
COPY internal/db/migrations /migrations
ENV GOOSE_DRIVER=postgres GOOSE_MIGRATION_DIR=/migrations
USER 65532:65532
ENTRYPOINT ["/goose"]
CMD ["up"]

FROM alpine:3.24 AS runtime
RUN apk add --no-cache ca-certificates
COPY --from=build /out/history /history
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/history"]
