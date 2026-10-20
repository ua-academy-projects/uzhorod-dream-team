FROM golang:1.26-alpine AS builder

WORKDIR /build

RUN apk add --no-cache tzdata

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -ldflags="-s -w" -o history ./cmd/history


FROM scratch

COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /build/history /app/history

ENTRYPOINT ["/app/history"]