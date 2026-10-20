package middleware

import (
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
)

type SettingsMiddleware struct {
}

func NewSettingsMiddleware() *SettingsMiddleware {
	return &SettingsMiddleware{}
}

func (m *SettingsMiddleware) SettingsMiddleware() fiber.Handler {
	return func(c *fiber.Ctx) error {
		id := c.Cookies("settings_id")

		if id == "" {
			id = uuid.New().String()

			c.Cookie(&fiber.Cookie{
				Name:     "settings_id",
				Value:    id,
				HTTPOnly: false,
				SameSite: "Lax",
				MaxAge:   60 * 60 * 24 * 365,
			})
		}

		c.Locals("settings_id", id)

		return c.Next()
	}
}
