# Postgres with the pgmq extension. pgmq is pure SQL, so only its control and
# SQL files are copied: same alpine base, the pgdata volume stays compatible.
FROM postgres:17-alpine AS pgmq
ARG PGMQ_VERSION=1.11.1
RUN apk add --no-cache make git \
 && git clone --depth 1 --branch "v${PGMQ_VERSION}" https://github.com/pgmq/pgmq.git /tmp/pgmq \
 && make -C /tmp/pgmq/pgmq-extension install

FROM postgres:17-alpine
COPY --from=pgmq /usr/local/share/postgresql/extension/pgmq* /usr/local/share/postgresql/extension/
