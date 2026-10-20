package handler

import (
	"fetcher/internal/service"
	"time"

	"github.com/gofiber/fiber/v2"
)

func RegisterFetcherRoutes(router fiber.Router) {
	svc := service.NewFetcherService("ETHUSD")

	router.Get("/", func(c *fiber.Ctx) error {
		fromStr := c.Query("from")
		toStr := c.Query("to")
		limit := c.QueryInt("limit", 1)

		var from *time.Time
		var to *time.Time

		if fromStr != "" {
			t, err := time.Parse(time.RFC3339, fromStr)
			if err != nil {
				return err
			}
			from = &t
		}
		if toStr != "" {
			t, err := time.Parse(time.RFC3339, toStr)
			if err != nil {
				return err
			}
			to = &t
		}

		res, err := svc.Fetch(c.Context(), from, to, limit)
		if err != nil {
			return err
		}

		return c.Status(fiber.StatusOK).JSON(res)
	})
}
