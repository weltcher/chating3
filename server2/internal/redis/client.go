package redis

import (
	"context"
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/go-redis/redis/v8"

	"server2/internal/config"
)

// Client wraps the Redis client with message-specific operations
type Client struct {
	rdb *redis.Client
	ctx context.Context
}

// NewClient creates a new Redis client
func NewClient(cfg config.RedisConfig) (*Client, error) {
	rdb := redis.NewClient(&redis.Options{
		Addr:     fmt.Sprintf("%s:%s", cfg.Host, cfg.Port),
		Password: cfg.Password,
		DB:       cfg.DB,
		PoolSize: 100, // High pool size for concurrent access
	})

	ctx := context.Background()

	// Test connection
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to Redis: %w", err)
	}

	return &Client{
		rdb: rdb,
		ctx: ctx,
	}, nil
}

// Close closes the Redis connection
func (c *Client) Close() error {
	return c.rdb.Close()
}

// GeneratePrivateKey generates a Redis key for private chat messages
// Format: 0-{receiverID}-{senderID}
func GeneratePrivateKey(receiverID, senderID int64) string {
	return fmt.Sprintf("0-%d-%d", receiverID, senderID)
}

// GenerateGroupKey generates a Redis key for group chat messages
// Format: 1-{receiverID}-{groupID}
func GenerateGroupKey(receiverID, groupID int64) string {
	return fmt.Sprintf("1-%d-%d", receiverID, groupID)
}

// GenerateSavePrivateKey generates a Redis key for saving private chat messages
// Format: 2-{senderID}-{receiverID}
func GenerateSavePrivateKey(senderID, receiverID int64) string {
	return fmt.Sprintf("2-%d-%d", senderID, receiverID)
}

// GenerateSaveGroupKey generates a Redis key for saving group chat messages
// Format: 3-{senderID}-{groupID}
func GenerateSaveGroupKey(senderID, groupID int64) string {
	return fmt.Sprintf("3-%d-%d", senderID, groupID)
}

// HSetMessage stores a message in a Redis hash map
// key: the hash key, field: the message ID, value: the full JSON string
func (c *Client) HSetMessage(key, field, value string) error {
	err := c.rdb.HSet(c.ctx, key, field, value).Err()
	if err != nil {
		return err
	}
	// 设置 7 天过期
	return c.rdb.Expire(c.ctx, key, 7*24*time.Hour).Err()
}

// HDelMessage deletes a specific field from a Redis hash map
// Used after Server A has safely stored the message in PostgreSQL
func (c *Client) HDelMessage(key, field string) error {
	return c.rdb.HDel(c.ctx, key, field).Err()
}

// AppendMessageID appends a message ID to the ordered queue for a given key
// If the key doesn't exist, it creates a new list
func (c *Client) AppendMessageID(key string, messageID int64) error {
	// Use RPUSH to append to the end of the list
	return c.rdb.RPush(c.ctx, key, messageID).Err()
}

// GetMessageIDs retrieves all message IDs for a given key
func (c *Client) GetMessageIDs(key string) ([]int64, error) {
	// Get all elements from the list
	result, err := c.rdb.LRange(c.ctx, key, 0, -1).Result()
	if err != nil {
		return nil, err
	}

	ids := make([]int64, 0, len(result))
	for _, s := range result {
		id, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			continue
		}
		ids = append(ids, id)
	}

	return ids, nil
}

// GetLatestMessageID retrieves the latest (last) message ID for a given key
func (c *Client) GetLatestMessageID(key string) (int64, error) {
	// Get the last element from the list
	result, err := c.rdb.LRange(c.ctx, key, -1, -1).Result()
	if err != nil {
		return 0, err
	}

	if len(result) == 0 {
		return 0, nil // No messages yet
	}

	return strconv.ParseInt(result[0], 10, 64)
}

// GetMessageIDsGreaterThan retrieves all message IDs greater than the given ID
func (c *Client) GetMessageIDsGreaterThan(key string, minID int64) ([]int64, error) {
	// Get all message IDs
	allIDs, err := c.GetMessageIDs(key)
	if err != nil {
		return nil, err
	}

	// Filter IDs greater than minID
	result := make([]int64, 0)
	for _, id := range allIDs {
		if id > minID {
			result = append(result, id)
		}
	}

	return result, nil
}

// KeyExists checks if a key exists in Redis
func (c *Client) KeyExists(key string) (bool, error) {
	result, err := c.rdb.Exists(c.ctx, key).Result()
	if err != nil {
		return false, err
	}
	return result > 0, nil
}

// SetKeyExpiration sets an expiration time for a key
// Messages older than 7 days will be automatically cleaned up
func (c *Client) SetKeyExpiration(key string, duration time.Duration) error {
	return c.rdb.Expire(c.ctx, key, duration).Err()
}

// CleanupOldMessages removes message IDs that are older than the specified threshold
// This helps keep the Redis memory usage under control
func (c *Client) CleanupOldMessages(key string, keepCount int64) error {
	// Keep only the last N messages
	return c.rdb.LTrim(c.ctx, key, -keepCount, -1).Err()
}

// BatchAppendMessageIDs appends multiple message IDs to a key
func (c *Client) BatchAppendMessageIDs(key string, messageIDs []int64) error {
	if len(messageIDs) == 0 {
		return nil
	}

	// Convert to interface slice for RPUSH
	args := make([]interface{}, len(messageIDs))
	for i, id := range messageIDs {
		args[i] = id
	}

	return c.rdb.RPush(c.ctx, key, args...).Err()
}

// GetAllKeysForReceiver retrieves all keys for a specific receiver
// This is useful for getting all conversations for a user
func (c *Client) GetAllKeysForReceiver(receiverID int64) ([]string, error) {
	// Pattern: *-{receiverID}-*
	pattern := fmt.Sprintf("*-%d-*", receiverID)
	return c.rdb.Keys(c.ctx, pattern).Result()
}

// GetAllMessageKeys retrieves all message queue keys (format: 0-*-* or 1-*-*)
func (c *Client) GetAllMessageKeys() ([]string, error) {
	// Get private chat keys (0-*-*)
	privateKeys, err := c.rdb.Keys(c.ctx, "0-*-*").Result()
	if err != nil {
		return nil, err
	}

	// Get group chat keys (1-*-*)
	groupKeys, err := c.rdb.Keys(c.ctx, "1-*-*").Result()
	if err != nil {
		return nil, err
	}

	// Combine both
	allKeys := append(privateKeys, groupKeys...)
	return allKeys, nil
}

// KeepOnlyLastMessageID keeps only the last message ID in the list for a given key
// Returns the number of removed elements
func (c *Client) KeepOnlyLastMessageID(key string) (int64, error) {
	// Get the list length first
	length, err := c.rdb.LLen(c.ctx, key).Result()
	if err != nil {
		return 0, err
	}

	// If list has 0 or 1 element, nothing to remove
	if length <= 1 {
		return 0, nil
	}

	// Keep only the last element by trimming from index -1 to -1
	err = c.rdb.LTrim(c.ctx, key, -1, -1).Err()
	if err != nil {
		return 0, err
	}

	// Return the number of removed elements
	return length - 1, nil
}

// CleanupAllQueues iterates through all message keys and keeps only the last message ID
// Returns total keys processed and total messages removed
func (c *Client) CleanupAllQueues() (keysProcessed int, messagesRemoved int64, err error) {
	keys, err := c.GetAllMessageKeys()
	if err != nil {
		return 0, 0, err
	}

	for _, key := range keys {
		removed, err := c.KeepOnlyLastMessageID(key)
		if err != nil {
			log.Printf("[Cleanup] Failed to cleanup key %s: %v", key, err)
			continue
		}
		if removed > 0 {
			log.Printf("[Cleanup] Key %s: removed %d old message IDs", key, removed)
		}
		messagesRemoved += removed
		keysProcessed++
	}

	return keysProcessed, messagesRemoved, nil
}

// GetSavedPrivateKeys retrieves all saved private message keys (format: 2-*-*)
func (c *Client) GetSavedPrivateKeys() ([]string, error) {
	return c.rdb.Keys(c.ctx, "2-*").Result()
}

// GetSavedGroupKeys retrieves all saved group message keys (format: 3-*-*)
func (c *Client) GetSavedGroupKeys() ([]string, error) {
	return c.rdb.Keys(c.ctx, "3-*").Result()
}

// HGetAll retrieves all field-value pairs from a Redis hash map
func (c *Client) HGetAll(key string) (map[string]string, error) {
	return c.rdb.HGetAll(c.ctx, key).Result()
}

// GetKeyTTL retrieves the remaining time-to-live of a key
// Returns -1 if the key exists but has no expiration, -2 if the key does not exist
func (c *Client) GetKeyTTL(key string) (time.Duration, error) {
	return c.rdb.TTL(c.ctx, key).Result()
}
