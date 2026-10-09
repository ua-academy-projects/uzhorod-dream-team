FROM node:24-alpine AS build
WORKDIR /src
RUN npm install --global pnpm@10.33.0
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN VITE_API_URL=/api/v1 pnpm run build

FROM nginx:stable-alpine-slim
COPY --from=build /src/dist /usr/share/nginx/html
COPY docker/default.conf.template /etc/nginx/templates/default.conf.template
ENV HISTORY_URL=http://kyiv-air-history:8081
EXPOSE 80
