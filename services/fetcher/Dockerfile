FROM golang:1.26-alpine AS builder

WORKDIR /build

RUN apk add --no-cache tzdata ca-certificates

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -ldflags="-s -w" -o fetcher ./cmd/fetcher


FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /build/fetcher /app/fetcher

CMD ["/app/fetcher"]