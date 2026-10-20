package handler

import (
	"history/internal/middleware"
	"history/internal/model"
	"history/internal/repository/settings"
	"history/internal/service"
	"log"

	"github.com/gofiber/fiber/v2"
)

func RegisterSettingsRoutes(router fiber.Router, deps *model.Dependencies) {
	var repo settings.Repository

	log.Printf(
		"DEBUG settings: CacheType=%q, expected=%q, equal=%t",
		deps.CacheType,
		model.CacheHStore,
		deps.CacheType == model.CacheHStore,
	)

	switch deps.CacheType {
	case model.CacheRedis:
		repo = settings.NewRedisRepository(deps.Redis)
	case model.CacheHStore:
		repo = settings.NewPSQLRepository(deps.Postgres)
	default:
		log.Fatalf("unsupported CACHE_TYPE: %s", deps.CacheType)
	}

	svc := service.NewSettingsService(repo, deps.CacheType)
	middleware := middleware.NewSettingsMiddleware()

	router.Use(middleware.SettingsMiddleware())

	router.Get("/", func(c *fiber.Ctx) error {
		id, ok := c.Locals("settings_id").(string)
		if !ok {
			return fiber.ErrInternalServerError
		}

		res, err := svc.GetSettings(c.Context(), id)
		if err != nil {
			return err
		}

		return c.Status(fiber.StatusOK).JSON(res)
	})

	router.Put("/", func(c *fiber.Ctx) error {
		id, ok := c.Locals("settings_id").(string)
		if !ok {
			return fiber.ErrInternalServerError
		}

		var settings model.Settings
		if err := c.BodyParser(&settings); err != nil {
			return fiber.ErrBadRequest
		}

		err := svc.SetSettings(c.Context(), id, settings)
		if err != nil {
			return err
		}

		return c.Status(fiber.StatusOK).JSON(settings)
	})
}
