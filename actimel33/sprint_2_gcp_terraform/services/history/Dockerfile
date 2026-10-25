# syntax=docker/dockerfile:1
FROM node:24-alpine AS deps
WORKDIR /app/services/history
COPY services/history/package.json services/history/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts

# Node only, no shell or npm.
FROM gcr.io/distroless/nodejs24-debian12:nonroot
WORKDIR /app/services/history
COPY --from=deps /app/services/history/node_modules ./node_modules
COPY services/history/package.json ./
COPY services/history/src ./src
COPY db/migrations /app/db/migrations
EXPOSE 3001
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:3001/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
# Entrypoint of the image is node itself.
CMD ["src/index.ts"]