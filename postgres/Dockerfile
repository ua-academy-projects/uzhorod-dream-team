# syntax=docker/dockerfile:1
ARG PG_IMAGE=postgres:16-alpine
FROM ${PG_IMAGE} AS build
ARG PGMQ_VERSION=1.13.0
ARG PG_CRON_VERSION=1.6.8
RUN apk add --no-cache build-base curl
WORKDIR /src
RUN curl -fsSL "https://github.com/pgmq/pgmq/archive/refs/tags/v${PGMQ_VERSION}.tar.gz" | tar xz \
 && curl -fsSL "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" | tar xz
RUN make -C "pgmq-${PGMQ_VERSION}/pgmq-extension" install DESTDIR=/out \
 && make -C "pg_cron-${PG_CRON_VERSION}" with_llvm=no install DESTDIR=/out

FROM ${PG_IMAGE}
COPY --from=build /out/usr/local/share/postgresql/extension/ /usr/local/share/postgresql/extension/
COPY --from=build /out/usr/local/lib/postgresql/pg_cron.so /usr/local/lib/postgresql/
