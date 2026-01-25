package main

import (
	"log"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"

	"server2/internal/config"
	"server2/internal/handlers"
	"server2/internal/redis"
	"server2/internal/scheduler"
	"server2/internal/socket"
)

func main() {
	// Load environment variables
	if err := godotenv.Load(); err != nil {
		log.Println("No .env file found, using environment variables")
	}

	// Initialize configuration
	cfg := config.Load()

	// Initialize Redis client
	redisClient, err := redis.NewClient(cfg.Redis)
	if err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}
	defer redisClient.Close()

	// Initialize WebSocket client to Server A
	wsClient := socket.NewClient(cfg.ServerA)
	go wsClient.Connect()

	// Initialize and start the scheduler for daily cleanup
	cleanupScheduler := scheduler.NewScheduler(redisClient)
	cleanupScheduler.Start()
	defer cleanupScheduler.Stop()

	// Initialize HTTP handlers
	handler := handlers.NewHandler(redisClient, wsClient)

	// Setup Gin router with high performance settings
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	router.Use(corsMiddleware())

	// API routes
	api := router.Group("/api")
	{
		// HTTP API 1: Sync latest messages (called after message_sent)
		// Receives new message IDs and stores them in Redis
		api.POST("/sync-message", handler.SyncMessage)

		// HTTP API 2: Periodic push local latest messages (called every 5 seconds by client)
		// Compares client's latest message IDs with Redis and triggers sync if needed
		api.POST("/check-sync", handler.CheckSync)
	}

	// Health check endpoint
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	// Start HTTP server
	port := cfg.HTTPPort
	if port == "" {
		port = "3002"
	}

	log.Printf("Server B starting on port %s", port)
	if err := router.Run(":" + port); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

// corsMiddleware handles CORS for all requests
func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}

		c.Next()
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
