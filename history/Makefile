.PHONY: build run clean migrate-up migrate-down db-up db-down redis-up redis-down rabbitmq-up rabbitmq-down

APP_NAME = history
BIN_DIR = bin
MAIN_PKG = ./cmd/history
POSTGRES_IMAGE = ghcr.io/pgmq/pg16-pgmq:v1.13.0@sha256:4b405e58f32c8687463be1b9befb46926034b9adc9e9b73570c0b3952f7dcfce

ifneq (,$(wildcard ./.env))
    include .env
    export
endif

GO_FILES := $(shell find . -type f -name '*.go' -not -path "./vendor/*")

${BIN_DIR}/${APP_NAME}: $(GO_FILES)
	@echo "Building ${APP_NAME}..."
	@mkdir -p ${BIN_DIR}
	go build -o ${BIN_DIR}/${APP_NAME} ${MAIN_PKG}

build: ${BIN_DIR}/${APP_NAME}

run: build
	@echo "Running ${APP_NAME}..."
	./${BIN_DIR}/${APP_NAME}

clean:
	@echo "Cleaning up..."
	@rm -rf ${BIN_DIR}

migrate-up:
	goose -dir internal/db/migrations postgres "${DATABASE_URL}" up

migrate-down:
	goose -dir internal/db/migrations postgres "${DATABASE_URL}" down

db-up:
	docker run --user root --env-file ../env/db.development.env -p 5432:5432 -v history_service_db_data:/var/lib/postgresql/data --name history-service-db --rm -d $(POSTGRES_IMAGE) postgres -c shared_preload_libraries=
	@echo "Started the DB container."

db-down:
	docker stop history-service-db
	@echo "Stopped the DB container."

redis-up:
	docker run -p 6379:6379 --name history-service-redis -v history_service_redis_data:/var/lib/redis --rm -d redis:8
	@echo "Started the Redis instance."

redis-down:
	docker stop history-service-redis
	@echo "Stopped the Redis instance."

rabbitmq-up:
	docker run -p 5672:5672 -p 15672:15672 --hostname history-service-rabbitmq --name history-service-rabbitmq -v history_service_rabbitmq_data:/var/lib/rabbitmq --rm -d rabbitmq:4-management
	@echo "Started the RabbitMQ instance."

rabbitmq-down:
	docker stop history-service-rabbitmq
	@echo "Stopped the RabbitMQ instance."
