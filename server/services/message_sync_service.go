package services

import (
	"bytes"
	"encoding/json"
	"net/http"
	"time"

	"youdu-server/utils"

	"github.com/spf13/viper"
)

// MessageSyncService 消息同步服务
// 负责在服务器A保存消息后，将消息同步到服务器B
type MessageSyncService struct {
	serverBBaseUrl string
	httpClient     *http.Client
}

var messageSyncServiceInstance *MessageSyncService

// GetMessageSyncService 获取消息同步服务单例
func GetMessageSyncService() *MessageSyncService {
	if messageSyncServiceInstance == nil {
		syncHost := viper.GetString("SYNC_SERVER_HOST")
		syncPort := viper.GetString("SYNC_SERVER_PORT")

		// 默认值
		if syncHost == "" {
			syncHost = "localhost"
		}
		if syncPort == "" {
			syncPort = "3002"
		}

		messageSyncServiceInstance = &MessageSyncService{
			serverBBaseUrl: "http://" + syncHost + ":" + syncPort,
			httpClient: &http.Client{
				Timeout: 10 * time.Second,
			},
		}
		utils.LogInfo("✅ [MessageSyncService] 初始化完成，服务器B地址: %s", messageSyncServiceInstance.serverBBaseUrl)
	}
	return messageSyncServiceInstance
}

// SyncPrivateMessage 同步私聊消息到服务器B
// receiverID: 接收者ID
// senderID: 发送者ID
// serverID: 消息在服务器A的数据库ID
func (s *MessageSyncService) SyncPrivateMessage(receiverID, senderID, serverID int) {
	go func() {
		// 生成私聊消息的key: 0-{接收者ID}-{发送者ID}
		key := "0-" + itoa(receiverID) + "-" + itoa(senderID)
		requestBody := map[string]int{key: serverID}

		s.doSyncRequest(requestBody, "私聊", serverID)
	}()
}

// SyncGroupMessage 同步群组消息到服务器B
// groupID: 群组ID
// serverID: 消息在服务器A的数据库ID
func (s *MessageSyncService) SyncGroupMessage(groupID, serverID int) {
	go func() {
		// 群组消息的key格式: 1-{群组ID}
		key := "1-" + itoa(groupID)
		requestBody := map[string]int{key: serverID}

		s.doSyncRequest(requestBody, "群组", serverID)
	}()
}

// doSyncRequest 执行同步请求
func (s *MessageSyncService) doSyncRequest(requestBody map[string]int, msgType string, serverID int) {
	jsonData, err := json.Marshal(requestBody)
	if err != nil {
		utils.LogDebug("[MessageSync] %s消息同步失败 - JSON序列化错误: %v", msgType, err)
		return
	}

	url := s.serverBBaseUrl + "/api/sync-message"
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		utils.LogDebug("[MessageSync] %s消息同步失败 - 创建请求错误: %v", msgType, err)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		utils.LogDebug("[MessageSync] %s消息同步失败 - 请求错误: %v, serverID: %d", msgType, err, serverID)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		utils.LogDebug("[MessageSync] %s消息同步成功 - serverID: %d", msgType, serverID)
	} else {
		utils.LogDebug("[MessageSync] %s消息同步失败 - 状态码: %d, serverID: %d", msgType, resp.StatusCode, serverID)
	}
}

// DeleteSavedPrivateMessage 删除Redis中已保存的私聊消息
// 在服务器A将消息保存到PostgreSQL后调用，表示数据已安全存储
func (s *MessageSyncService) DeleteSavedPrivateMessage(senderID, receiverID, clientMessageID int) {
	go func() {
		requestBody := map[string]interface{}{
			"type":              "private",
			"sender_id":         senderID,
			"receiver_id":       receiverID,
			"client_message_id": clientMessageID,
		}
		s.doDeleteSavedRequest(requestBody, "私聊", clientMessageID)
	}()
}

// DeleteSavedGroupMessage 删除Redis中已保存的群组消息
// 在服务器A将消息保存到PostgreSQL后调用，表示数据已安全存储
func (s *MessageSyncService) DeleteSavedGroupMessage(senderID, groupID, clientGroupMessageID int) {
	go func() {
		requestBody := map[string]interface{}{
			"type":                    "group",
			"sender_id":               senderID,
			"group_id":                groupID,
			"client_group_message_id": clientGroupMessageID,
		}
		s.doDeleteSavedRequest(requestBody, "群组", clientGroupMessageID)
	}()
}

// doDeleteSavedRequest 执行删除已保存消息的请求
func (s *MessageSyncService) doDeleteSavedRequest(requestBody map[string]interface{}, msgType string, clientID int) {
	jsonData, err := json.Marshal(requestBody)
	if err != nil {
		utils.LogDebug("[DeleteSaved] %s消息删除失败 - JSON序列化错误: %v", msgType, err)
		return
	}

	url := s.serverBBaseUrl + "/api/delete-saved-message"
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		utils.LogDebug("[DeleteSaved] %s消息删除失败 - 创建请求错误: %v", msgType, err)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		utils.LogDebug("[DeleteSaved] %s消息删除失败 - 请求错误: %v, clientID: %d", msgType, err, clientID)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		utils.LogDebug("[DeleteSaved] %s消息已从Redis删除 - clientID: %d", msgType, clientID)
	} else {
		utils.LogDebug("[DeleteSaved] %s消息删除失败 - 状态码: %d, clientID: %d", msgType, resp.StatusCode, clientID)
	}
}

// itoa 简单的整数转字符串
func itoa(i int) string {
	if i == 0 {
		return "0"
	}

	var result []byte
	negative := false
	if i < 0 {
		negative = true
		i = -i
	}

	for i > 0 {
		result = append([]byte{byte('0' + i%10)}, result...)
		i /= 10
	}

	if negative {
		result = append([]byte{'-'}, result...)
	}

	return string(result)
}
