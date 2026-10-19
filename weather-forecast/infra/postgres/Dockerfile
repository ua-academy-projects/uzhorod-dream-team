FROM alpine:3.23 AS extension

RUN apk add --no-cache ca-certificates curl tar

WORKDIR /build
RUN curl --fail --location --retry 3 \
      https://github.com/pgmq/pgmq/archive/refs/tags/v1.13.0.tar.gz -o pgmq.tar.gz \
    && echo 'c980705ffa2a731b69f3d26be5650d6fbcc76b2b9add67b138da4ee74a4579a5  pgmq.tar.gz' | sha256sum -c - \
    && tar -xzf pgmq.tar.gz \
    && mkdir /extension \
    && cp pgmq-1.13.0/pgmq-extension/pgmq.control /extension/ \
    && cp pgmq-1.13.0/pgmq-extension/sql/pgmq--*.sql /extension/ \
    && cp pgmq-1.13.0/pgmq-extension/sql/pgmq.sql /extension/pgmq--1.13.0.sql

FROM postgres:18-alpine

COPY --from=extension /extension/ /usr/local/share/postgresql/extension/
COPY --from=extension /build/pgmq-1.13.0/LICENSE /usr/local/share/licenses/pgmq/LICENSE
RUN test -f "$(pg_config --sharedir)/extension/pgmq.control" \
    && test -f "$(pg_config --sharedir)/extension/hstore.control"
