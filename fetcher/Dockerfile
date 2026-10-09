FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fetcher ./cmd/fetcher

FROM alpine:3.24
RUN apk add --no-cache ca-certificates
COPY --from=build /out/fetcher /fetcher
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/fetcher"]
