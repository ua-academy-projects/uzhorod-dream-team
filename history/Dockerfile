# Image of History (API + UI). Built in history-vm by provision/history.sh.
# The build context is the project folder (it has both history/ and ui/):
#   docker build -f history/Dockerfile -t weather-history:local /home/vagrant/weather-history
# What may enter the context is listed in the .dockerignore of the project folder.

# Stage 1 "build": Go compiler and libraries. Only the binary is taken from it.
FROM golang:1.26 AS build
WORKDIR /src

# Libraries first: this layer is rebuilt only when go.mod or go.sum change.
COPY history/go.mod history/go.sum ./
RUN go mod download

COPY history/*.go ./
# CGO_ENABLED=0: a static binary that needs no C libraries, so it runs in an image without them.
# GOMEMLIMIT: the VM has little memory, the compiler frees memory more often.
# GOTOOLCHAIN=local: use Go from this image, do not download another one.
# -s -w: without debug information (smaller binary).
RUN CGO_ENABLED=0 GOMEMLIMIT=350MiB GOTOOLCHAIN=local \
    go build -trimpath -ldflags="-s -w" -o /out/history . \
 && go version -m /out/history | grep -q 'CGO_ENABLED=0'

# Stage 2: the final image. distroless/static has no shell and no package manager, only
# CA certificates, time zones and the user "nonroot" (uid 65532).
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/history /app/bin/history
COPY ui/ /app/ui/

# History reads .env from the current folder and the UI from ../ui.
# .env is not in the image: provision/history.sh mounts it at run time (read-only).
WORKDIR /app/history
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app/bin/history"]
