FROM golang:1.26-alpine AS builder
WORKDIR /src


COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/fetcher ./cmd


FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY --from=builder /out/fetcher /fetcher

USER 65532:65532
EXPOSE 8000
ENTRYPOINT ["/fetcher"]
