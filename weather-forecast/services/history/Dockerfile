FROM golang:1.27 AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . ./

RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/history ./cmd/history

FROM scratch

COPY --from=builder /out/history /history

USER 65532:65532
EXPOSE 8002
ENTRYPOINT ["/history"]
