FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund

COPY . .
RUN npm run build

FROM nginx:1.30-alpine-slim
COPY templates/default.conf.template templates/app.inc.template /etc/nginx/templates/
COPY --from=build /app/dist /usr/share/nginx/html
