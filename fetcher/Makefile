.PHONY: build run clean test

APP_NAME = fetcher
BIN_DIR = bin
MAIN_PKG = ./cmd/fetcher

build:
	@echo "Building ${APP_NAME}..."
	@mkdir -p ${BIN_DIR}
	go build -o ${BIN_DIR}/${APP_NAME} ${MAIN_PKG}

run: build
	@echo "Running ${APP_NAME}..."
	./${BIN_DIR}/${APP_NAME}

clean:
	@echo "Cleaning up..."
	@rm -rf ${BIN_DIR}

test:
	@echo "Running tests..."
	go test -v ./...
