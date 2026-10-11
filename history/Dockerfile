# syntax=docker/dockerfile:1
ARG ALPINE_VERSION=3.24
FROM node:22-alpine${ALPINE_VERSION} AS deps
RUN apk add --no-cache binutils && strip /usr/local/bin/node
WORKDIR /app
COPY package.json package-lock.json ./
COPY history/package.json history/
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --workspace=history --no-audit --no-fund \
 && find node_modules -type f \( -name '*.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' -o -iname '*.md' \) -delete

FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache libstdc++ && addgroup -S app && adduser -S -G app app
COPY --from=deps /usr/local/bin/node /usr/local/bin/node
COPY --from=deps /app/node_modules /app/node_modules
COPY history/ /app/history/
WORKDIR /app/history
ENV NODE_ENV=production PORT=3001
USER app
EXPOSE 3001
CMD ["node", "src/server.js"]
