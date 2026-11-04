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

FROM alpine:3.23 AS pgmq-download
RUN apk add --no-cache curl
RUN mkdir /pgmq && \
    curl -fsSL https://raw.githubusercontent.com/pgmq/pgmq/v1.13.0/pgmq-extension/sql/pgmq.sql -o /pgmq/pgmq.sql && \
    curl -fsSL https://raw.githubusercontent.com/pgmq/pgmq/v1.13.0/LICENSE -o /pgmq/LICENSE && \
    echo 'bf7e66c75ed771df0c5f7cb2b9f0123ca77992daacd56e3911d1894a3efa99de  /pgmq/pgmq.sql' | sha256sum -c - && \
    echo 'a3ce61e0031bdcad1024b1bf50ded2359602160f00e0cac8e509752273df6179  /pgmq/LICENSE' | sha256sum -c -

FROM postgres:16-alpine AS migrate
COPY --from=goose-build /out/goose /goose
COPY --from=pgmq-download /pgmq /pgmq
COPY internal/db/migrations /migrations
COPY scripts/migrate.sh /migrate.sh
ENV GOOSE_DRIVER=postgres GOOSE_MIGRATION_DIR=/migrations
USER 65532:65532
ENTRYPOINT ["/bin/sh", "/migrate.sh"]
CMD ["up"]

FROM scratch AS runtime
COPY --from=build /out/history /history
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/history"]
