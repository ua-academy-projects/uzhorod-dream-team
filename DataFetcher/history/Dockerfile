FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -buildid=" -o /out/history ./cmd

FROM scratch

COPY --from=builder /out/history /history

EXPOSE 8000
ENTRYPOINT ["/history"]
