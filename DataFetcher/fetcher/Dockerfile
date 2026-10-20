FROM golang:1.25-alpine AS builder
WORKDIR /src


COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/fetcher ./cmd


FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY --from=builder /out/fetcher /fetcher

EXPOSE 8000
ENTRYPOINT ["/fetcher"]
