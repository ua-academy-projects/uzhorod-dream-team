package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"history/config"
	"history/internal/model"
	"history/internal/repository/history"
	"history/internal/router"
	"history/internal/service"
	"log"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/redis/go-redis/v9"
)

func connectRabbitMQ(
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

func connectRedis(ctx context.Context, cfg config.Redis) *redis.Client {
	conn := redis.NewClient(&redis.Options{
		Addr:     fmt.Sprintf("%s:%s", cfg.Host, cfg.Port),
		Password: cfg.Password,
		DB:       0,
	})

	_, err := conn.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("unable to connect to redis: %v\n", err)
	}

	return conn
}

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

func fetchInitialHistory(ctx context.Context, svc *service.HistoryService) error {
	last, err := svc.GetLastOpenTime(ctx, "ETHUSD")
	if err != nil {
		return err
	}

	if last == nil {
		from := time.Now().Add(-24 * time.Hour)
		to := time.Now()

		_, err := svc.FetchInitialBars(ctx, from, to)
		if err != nil {
			return fmt.Errorf("failed to fetch initial bars: %w", err)
		}

		return nil
	}

	from := last.Add(time.Minute)
	to := time.Now()

	_, err = svc.FetchInitialBars(ctx, from, to)
	if err != nil {
		return fmt.Errorf("failed to fetch initial bars: %w", err)
	}

	return nil
}

func listenBars(
	ctx context.Context,
	ch *amqp.Channel,
	pg *pgxpool.Pool,
	svc *service.HistoryService,
	queueType model.QueueType,
) error {
	switch queueType {
	case model.QueueRabbitMQ:
		if ch == nil {
			return fmt.Errorf("RabbitMQ channel is nil")
		}

		if err := ch.Qos(10, 0, false); err != nil {
			return fmt.Errorf("set consumer QoS: %w", err)
		}

		messages, err := ch.Consume(
			"bars",
			"history",
			false,
			false,
			false,
			false,
			nil,
		)
		if err != nil {
			return fmt.Errorf("consume bars: %w", err)
		}

		defer ch.Cancel("history", false)

		for {
			select {
			case <-ctx.Done():
				return nil
			case msg, ok := <-messages:
				if !ok {
					return fmt.Errorf("RabbitMQ delivery channel closed")
				}

				var bar model.Bar

				if err := json.Unmarshal(msg.Body, &bar); err != nil {
					log.Printf("invalid bar message: %v", err)

					if nackErr := msg.Nack(false, false); nackErr != nil {
						return fmt.Errorf("reject invalid message: %w", nackErr)
					}

					continue
				}

				if err := svc.SaveBars(ctx, bar.Symbol, []model.Bar{bar}); err != nil {
					log.Printf("failed to save bar: %v", err)

					if nackErr := msg.Nack(false, true); nackErr != nil {
						return fmt.Errorf("requeue bar message: %w", nackErr)
					}

					continue
				}

				if err := msg.Ack(false); err != nil {
					return fmt.Errorf("ack bar message: %w", err)
				}
			}
		}
	case model.QueuePGMQ:
		if pg == nil {
			return fmt.Errorf("PostgreSQL pool is nil")
		}

		for {
			if ctx.Err() != nil {
				return nil
			}

			var msgID int64
			var body []byte

			err := pg.QueryRow(
				ctx,
				"SELECT msg_id, message FROM pgmq.read($1, $2, $3::int)",
				"bars",
				30,
				1,
			).Scan(&msgID, &body)

			if err != nil {
				if ctx.Err() != nil {
					return nil
				}

				if errors.Is(err, pgx.ErrNoRows) {
					select {
					case <-ctx.Done():
						return nil
					case <-time.After(time.Second):
						continue
					}
				}

				return fmt.Errorf("read bar message: %w", err)
			}

			log.Printf("PGMQ: received message id=%d", msgID)

			var bar model.Bar
			if err := json.Unmarshal(body, &bar); err != nil {
				log.Printf("PGMQ: invalid message id=%d: %v", msgID, err)
				continue
			}

			if err := svc.SaveBars(ctx, bar.Symbol, []model.Bar{bar}); err != nil {
				log.Printf("PGMQ: failed to save message id=%d: %v", msgID, err)
				continue
			}

			log.Printf(
				"PGMQ: saved bar message id=%d symbol=%s open_time=%s",
				msgID,
				bar.Symbol,
				bar.OpenTime,
			)

			_, err = pg.Exec(
				ctx,
				"SELECT pgmq.delete($1::text, $2::bigint)",
				"bars",
				msgID,
			)
			if err != nil {
				return fmt.Errorf("delete processed bar message %d: %w", msgID, err)
			}

			log.Printf("PGMQ: deleted message id=%d", msgID)
		}
	default:
		return fmt.Errorf("unsupported queue type: %s", queueType)
	}
}

func main() {
	ctx := context.Background()
	cfg := config.LoadConfig()

	log.Printf(
		"DEBUG main: CacheType=%q, CacheHStore=%q, equal=%t",
		cfg.CacheType,
		model.CacheHStore,
		cfg.CacheType == model.CacheHStore,
	)

	pgPool := connectPSQL(ctx, cfg.PSQL)
	defer pgPool.Close()

	var redisClient *redis.Client
	if cfg.CacheType == model.CacheRedis {
		redisClient = connectRedis(ctx, cfg.Redis)
	} else if cfg.CacheType != model.CacheHStore {
		log.Fatalf("unsupported CACHE_TYPE: %s", cfg.CacheType)
	}

	repo := history.NewRepository(pgPool)
	svc := service.NewHistoryService(repo)

	if err := fetchInitialHistory(ctx, svc); err != nil {
		log.Fatalf("failed to initialize history: %v", err)
	}

	switch cfg.QueueType {
	case model.QueueRabbitMQ:
		rabbitConn, rabbitCh := connectRabbitMQ(cfg.RabbitMQ)
		defer rabbitConn.Close()
		defer rabbitCh.Close()

		go func() {
			if err := listenBars(ctx, rabbitCh, nil, svc, model.QueueRabbitMQ); err != nil {
				log.Printf("RabbitMQ consumer stopped: %v", err)
			}
		}()
	case model.QueuePGMQ:
		go func() {
			if err := listenBars(ctx, nil, pgPool, svc, model.QueuePGMQ); err != nil {
				log.Printf("PSQL consumer stopped: %v", err)
			}
		}()
	default:
		log.Fatalf("unsupported queue type: %s", cfg.QueueType)
	}

	app := fiber.New()
	app.Use(logger.New())

	app.Use(cors.New((cors.Config{
		// AllowOrigins: fmt.Sprintf("http://%s:%s", cfg.UI.Host, cfg.UI.Port),
		AllowOriginsFunc: func(origin string) bool {
			return true
		},
		AllowMethods:     "GET,POST,PUT,PATCH,DELETE,OPTIONS",
		AllowHeaders:     "Origin, Content-Type, Cache-Control, Accept, Authorization",
		ExposeHeaders:    "Content-Length",
		AllowCredentials: true,
	})))

	r := router.Router{
		App: app,
		Deps: &model.Dependencies{
			Postgres:  pgPool,
			Redis:     redisClient,
			CacheType: cfg.CacheType,
		},
	}

	r.InitRoutes()

	log.Fatal(app.Listen(cfg.Host + ":" + cfg.Port))
}
