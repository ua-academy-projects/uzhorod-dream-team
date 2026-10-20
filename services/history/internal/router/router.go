package router

import (
	"history/internal/handler"
	"history/internal/model"

	"github.com/gofiber/fiber/v2"
)

type Router struct {
	App  *fiber.App
	Deps *model.Dependencies
}

func (r *Router) InitRoutes() {
	api := r.App.Group("/api")

	handler.RegisterHistoryRoutes(api.Group("/history"), r.Deps)
	handler.RegisterSettingsRoutes(api.Group("/settings"), r.Deps)
}
