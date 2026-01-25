package scheduler

import (
	"log"
	"time"

	"server2/internal/redis"
)

// Scheduler handles scheduled tasks
type Scheduler struct {
	redisClient *redis.Client
	stopChan    chan struct{}
}

// NewScheduler creates a new scheduler instance
func NewScheduler(redisClient *redis.Client) *Scheduler {
	return &Scheduler{
		redisClient: redisClient,
		stopChan:    make(chan struct{}),
	}
}

// Start begins the scheduler
func (s *Scheduler) Start() {
	go s.runDailyCleanup()
	log.Println("[Scheduler] Started daily cleanup scheduler (runs at 01:30 AM)")
}

// Stop stops the scheduler
func (s *Scheduler) Stop() {
	close(s.stopChan)
	log.Println("[Scheduler] Stopped")
}

// runDailyCleanup runs the cleanup task at 01:30 AM every day
func (s *Scheduler) runDailyCleanup() {
	for {
		// Calculate duration until next 01:30 AM
		now := time.Now()
		next := time.Date(now.Year(), now.Month(), now.Day(), 1, 30, 0, 0, now.Location())
		
		// If it's already past 01:30 today, schedule for tomorrow
		if now.After(next) {
			next = next.Add(24 * time.Hour)
		}
		
		duration := next.Sub(now)
		log.Printf("[Scheduler] Next cleanup scheduled at %s (in %v)", next.Format("2006-01-02 15:04:05"), duration)
		
		select {
		case <-time.After(duration):
			s.executeCleanup()
		case <-s.stopChan:
			return
		}
	}
}

// executeCleanup performs the actual cleanup task
func (s *Scheduler) executeCleanup() {
	log.Println("[Scheduler] Starting daily Redis queue cleanup...")
	startTime := time.Now()
	
	keysProcessed, messagesRemoved, err := s.redisClient.CleanupAllQueues()
	
	elapsed := time.Since(startTime)
	
	if err != nil {
		log.Printf("[Scheduler] Cleanup failed: %v", err)
		return
	}
	
	log.Printf("[Scheduler] Cleanup completed in %v: processed %d keys, removed %d old message IDs",
		elapsed, keysProcessed, messagesRemoved)
}

// RunCleanupNow executes the cleanup task immediately (for testing/manual trigger)
func (s *Scheduler) RunCleanupNow() {
	s.executeCleanup()
}
