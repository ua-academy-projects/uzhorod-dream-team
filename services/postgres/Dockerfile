FROM postgres:16-alpine AS build
ARG PG_CRON_VERSION=1.6.8
ARG PGMQ_VERSION=1.13.0
RUN apk add --no-cache build-base curl
WORKDIR /build
RUN curl -fsSL "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" | tar xz \
 && make -C "pg_cron-${PG_CRON_VERSION}" with_llvm=no \
 && make -C "pg_cron-${PG_CRON_VERSION}" with_llvm=no install DESTDIR=/out
RUN curl -fsSL "https://github.com/pgmq/pgmq/archive/refs/tags/v${PGMQ_VERSION}.tar.gz" | tar xz \
 && install -D -m 644 "pgmq-${PGMQ_VERSION}/pgmq-extension/pgmq.control" /out/usr/local/share/postgresql/extension/pgmq.control \
 && install -D -m 644 "pgmq-${PGMQ_VERSION}/pgmq-extension/sql/pgmq.sql" "/out/usr/local/share/postgresql/extension/pgmq--${PGMQ_VERSION}.sql"

FROM postgres:16-alpine
COPY --from=build /out/usr/local /usr/local
