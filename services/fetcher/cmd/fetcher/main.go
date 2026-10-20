package main

import (
	"context"
	"encoding/json"
	"fetcher/config"
	"fetcher/internal/model"
	"fetcher/internal/monitor"
	"fetcher/internal/router"
	"fetcher/internal/service"
	"fmt"
	"log"
	"sort"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/jackc/pgx/v5/pgxpool"
	amqp "github.com/rabbitmq/amqp091-go"
)

const (
	INTERVAL = 1 * time.Minute
)

func connectPSQL(ctx context.Context, cfg config.PSQL) *pgxpool.Pool {
	url := fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s",
		cfg.User,
		cfg.Password,
		cfg.Host,
		cfg.Port,
		cfg.Database,
	)

	conn, err := pgxpool.New(ctx, url)
	if err != nil {
		log.Fatalf("unable to connect to psql: %v\n", err)
	}

	err = conn.Ping(ctx)
	if err != nil {
		log.Fatalf("failed to ping psql: %v", err)
	}

	return conn
}

func connectRabbitMQ(
	ctx context.Context,
	cfg config.RabbitMQ,
) (*amqp.Connection, *amqp.Channel) {
	url := fmt.Sprintf(
		"amqp://%s:%s@%s:%s/",
		cfg.User,
		cfg.Password,
		cfg.Host,
		cfg.Port,
	)

	conn, err := amqp.Dial(url)
	if err != nil {
		log.Fatalf("unable to connect to RabbitMQ: %v", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		log.Fatalf("unable to open RabbitMQ channel: %v", err)
	}

	_, err = ch.QueueDeclare(
		"bars",
		true,
		false,
		false,
		false,
		nil,
	)
	if err != nil {
		ch.Close()
		conn.Close()
		log.Fatalf("unable to declare queue: %v", err)
	}

	return conn, ch
}

func ticker(
	ctx context.Context,
	ch *amqp.Channel,
	pg *pgxpool.Pool,
	queueType model.QueueType,
) error {
	svc := service.NewFetcherService("ETHUSD")

	go monitor.Ticker(ctx, INTERVAL, func() {
		response, err := svc.Fetch(ctx, nil, nil, 1)
		if err != nil {
			log.Printf("failed to fetch bars: %v", err)
			return
		}

		sort.Slice(response.Bars, func(i, j int) bool {
			return response.Bars[i].OpenTime.Before(response.Bars[j].OpenTime)
		})

		if len(response.Bars) == 0 {
			return
		}

		log.Printf(
			"fetched %d bars: %s -> %s",
			len(response.Bars),
			response.Bars[0].OpenTime,
			response.Bars[len(response.Bars)-1].OpenTime,
		)

		for _, bar := range response.Bars {
			log.Printf(
				"publishing bar in %s: open_time=%s is_open=%t",
				queueType,
				bar.OpenTime,
				bar.IsOpen,
			)

			message := map[string]interface{}{
				"symbol":     response.Symbol,
				"openTime":   bar.OpenTime,
				"open":       bar.Open,
				"high":       bar.High,
				"low":        bar.Low,
				"close":      bar.Close,
				"volume":     bar.Volume,
				"tickVolume": bar.TickVolume,
				"isOpen":     bar.IsOpen,
				"timestamp":  time.Now(),
			}

			body, err := json.Marshal(message)
			if err != nil {
				log.Printf("failed to encode bar: %v", err)
				continue
			}

			switch queueType {
			case model.QueueRabbitMQ:
				if ch == nil {
					log.Printf("RabbitMQ channel is nil")
					continue
				}

				err = ch.PublishWithContext(
					ctx,
					"",
					"bars",
					false,
					false,
					amqp.Publishing{
						ContentType:  "application/json",
						DeliveryMode: 2,
						Body:         body,
					},
				)
			case model.QueuePGMQ:
				if pg == nil {
					log.Printf("PostgreSQL pool is nil")
					continue
				}

				_, err := pg.Exec(ctx, "SELECT pgmq.create($1)", "bars")
				if err != nil {
					log.Fatalf("failed to create PGMQ queue: %v", err)
					continue
				}

				var msgID int64
				err = pg.QueryRow(
					ctx,
					"SELECT * FROM pgmq.send($1, $2, $3::int)",
					"bars",
					body,
					0,
				).Scan(&msgID)

			default:
				log.Printf("unsupported queue type: %s", queueType)
				continue
			}

			if err != nil {
				log.Printf("failed to publish bar: %v", err)
				continue
			}

		}
	})

	return nil
}

func main() {
	ctx := context.Background()
	cfg := config.LoadConfig()

	switch cfg.QueueType {
	case model.QueueRabbitMQ:
		rabbitConn, rabbitCh := connectRabbitMQ(ctx, cfg.RabbitMQ)
		defer rabbitConn.Close()
		defer rabbitCh.Close()

		if err := ticker(ctx, rabbitCh, nil, model.QueueRabbitMQ); err != nil {
			log.Fatalf("failed to start ticker: %v", err)
		}

	case model.QueuePGMQ:
		pgPool := connectPSQL(ctx, cfg.PSQL)
		defer pgPool.Close()

		if err := ticker(ctx, nil, pgPool, model.QueuePGMQ); err != nil {
			log.Fatalf("failed to start ticker: %v", err)
		}

	default:
		log.Fatalf("unsupported queue type: %s", cfg.QueueType)
	}

	app := fiber.New()
	app.Use(logger.New())

	app.Use(cors.New((cors.Config{
		AllowOrigins:     "*",
		AllowMethods:     "GET,POST,PUT,PATCH,DELETE,OPTIONS",
		AllowHeaders:     "Origin, Content-Type, Cache-Control, Accept, Authorization, app-os, app-device, app-browser",
		ExposeHeaders:    "Content-Length",
		AllowCredentials: false,
	})))

	r := router.Router{
		App: app,
	}

	r.InitRoutes()

	log.Fatal(app.Listen(cfg.Host + ":" + cfg.Port))
}
