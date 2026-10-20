package handler

import (
	"history/internal/model"
	"history/internal/repository/history"
	"history/internal/service"
	"time"

	"github.com/gofiber/fiber/v2"
)

func RegisterHistoryRoutes(router fiber.Router, deps *model.Dependencies) {
	repo := history.NewRepository(deps.Postgres)
	svc := service.NewHistoryService(repo)

	router.Get("/:symbol", func(c *fiber.Ctx) error {
		dateStr := c.Query("from")
		symbol := c.Params("symbol")

		date, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			return fiber.NewError(
				fiber.StatusBadRequest,
				"invalid date format, expected YYYY-MM-DD",
			)
		}

		res, err := svc.GetHistory(c.Context(), symbol, date)
		if err != nil {
			return err
		}

		return c.Status(fiber.StatusOK).JSON(res)
	})

	router.Get("/:symbol/last", func(c *fiber.Ctx) error {
		symbol := c.Params("symbol")

		c.Set("Cache-Control", "no-store")

		res, err := svc.GetLast(c.Context(), symbol)
		if err != nil {
			return err
		}

		return c.Status(fiber.StatusOK).JSON(res)
	})
}
