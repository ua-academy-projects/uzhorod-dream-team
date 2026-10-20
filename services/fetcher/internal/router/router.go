package router

import (
	"fetcher/internal/handler"
	"fetcher/internal/model"

	"github.com/gofiber/fiber/v2"
)

type Router struct {
	App  *fiber.App
	Deps *model.Dependencies
}

func (r *Router) InitRoutes() {
	api := r.App.Group("/api")

	handler.RegisterFetcherRoutes(api.Group("/fetcher"))
}
