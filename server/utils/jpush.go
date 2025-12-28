package utils

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/spf13/viper"
)

// JPushConfig 极光推送配置
type JPushConfig struct {
	AppKey       string
	MasterSecret string
	BaseURL      string
}

// JPushClient 极光推送客户端
type JPushClient struct {
	config     JPushConfig
	httpClient *http.Client
}

// JPushMessage 推送消息结构
type JPushMessage struct {
	Platform     interface{}            `json:"platform"`               // 推送平台: "all" 或 ["android", "ios"]
	Audience     interface{}            `json:"audience"`               // 推送目标
	Notification *JPushNotification     `json:"notification,omitempty"` // 通知内容
	Message      *JPushCustomMessage    `json:"message,omitempty"`      // 自定义消息
	Options      *JPushOptions          `json:"options,omitempty"`      // 可选参数
}

// JPushNotification 通知内容
type JPushNotification struct {
	Alert   string                 `json:"alert,omitempty"`   // 通知内容
	Android *JPushAndroidNotify    `json:"android,omitempty"` // Android 专属
	IOS     *JPushIOSNotify        `json:"ios,omitempty"`     // iOS 专属
}

// JPushAndroidNotify Android 通知
type JPushAndroidNotify struct {
	Alert      string                 `json:"alert"`                 // 通知内容
	Title      string                 `json:"title,omitempty"`       // 通知标题
	BuilderID  int                    `json:"builder_id,omitempty"`  // 通知栏样式 ID
	ChannelID  string                 `json:"channel_id,omitempty"`  // Android 8.0+ 通知渠道
	Priority   int                    `json:"priority,omitempty"`    // 通知优先级 -2~2
	Category   string                 `json:"category,omitempty"`    // 通知类别
	Style      int                    `json:"style,omitempty"`       // 通知栏样式类型
	AlertType  int                    `json:"alert_type,omitempty"`  // 通知提醒方式
	Extras     map[string]interface{} `json:"extras,omitempty"`      // 扩展字段
}

// JPushIOSNotify iOS 通知
type JPushIOSNotify struct {
	Alert            interface{}            `json:"alert"`                        // 通知内容
	Sound            string                 `json:"sound,omitempty"`              // 通知声音
	Badge            interface{}            `json:"badge,omitempty"`              // 角标数字
	ContentAvailable bool                   `json:"content-available,omitempty"`  // 静默推送
	MutableContent   bool                   `json:"mutable-content,omitempty"`    // 可变内容
	Category         string                 `json:"category,omitempty"`           // 通知类别
	Extras           map[string]interface{} `json:"extras,omitempty"`             // 扩展字段
}

// JPushCustomMessage 自定义消息（透传消息）
type JPushCustomMessage struct {
	MsgContent  string                 `json:"msg_content"`            // 消息内容
	Title       string                 `json:"title,omitempty"`        // 消息标题
	ContentType string                 `json:"content_type,omitempty"` // 消息类型
	Extras      map[string]interface{} `json:"extras,omitempty"`       // 扩展字段
}

// JPushOptions 可选参数
type JPushOptions struct {
	SendNo          int    `json:"sendno,omitempty"`            // 推送序号
	TimeToLive      int    `json:"time_to_live,omitempty"`      // 离线消息保留时长(秒)，默认86400(1天)
	OverrideMsgID   int64  `json:"override_msg_id,omitempty"`   // 覆盖消息ID
	ApnsProduction  bool   `json:"apns_production"`             // iOS 是否生产环境
	ApnsCollapseID  string `json:"apns_collapse_id,omitempty"`  // iOS 通知折叠ID
	BigPushDuration int    `json:"big_push_duration,omitempty"` // 大推送缓慢推送时长
}

// JPushResponse 推送响应
type JPushResponse struct {
	SendNo string `json:"sendno"`
	MsgID  string `json:"msg_id"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// 全局极光推送客户端
var jpushClient *JPushClient

// InitJPush 初始化极光推送客户端
func InitJPush() error {
	appKey := viper.GetString("JPUSH_APP_KEY")
	masterSecret := viper.GetString("JPUSH_MASTER_SECRET")

	if appKey == "" || masterSecret == "" {
		LogWarning("极光推送未配置，跳过初始化 (JPUSH_APP_KEY 或 JPUSH_MASTER_SECRET 为空)")
		return nil
	}

	jpushClient = &JPushClient{
		config: JPushConfig{
			AppKey:       appKey,
			MasterSecret: masterSecret,
			BaseURL:      "https://api.jpush.cn/v3/push",
		},
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}

	LogInfo("极光推送初始化成功, AppKey: %s", appKey)
	return nil
}

// GetJPushClient 获取极光推送客户端
func GetJPushClient() *JPushClient {
	return jpushClient
}

// getAuthHeader 获取认证头
func (c *JPushClient) getAuthHeader() string {
	auth := c.config.AppKey + ":" + c.config.MasterSecret
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(auth))
}

// Push 发送推送
func (c *JPushClient) Push(msg *JPushMessage) (*JPushResponse, error) {
	if c == nil {
		return nil, fmt.Errorf("极光推送客户端未初始化")
	}

	jsonData, err := json.Marshal(msg)
	if err != nil {
		return nil, fmt.Errorf("序列化推送消息失败: %v", err)
	}

	LogDebug("发送极光推送: %s", string(jsonData))

	req, err := http.NewRequest("POST", c.config.BaseURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("创建请求失败: %v", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", c.getAuthHeader())

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("发送请求失败: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读取响应失败: %v", err)
	}

	LogDebug("极光推送响应: %s", string(body))

	var result JPushResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("解析响应失败: %v", err)
	}

	if result.Error != nil {
		return &result, fmt.Errorf("推送失败: code=%d, message=%s", result.Error.Code, result.Error.Message)
	}

	return &result, nil
}

// PushToUser 推送给指定用户（通过别名）
// userID: 用户ID
// title: 通知标题
// content: 通知内容
// extras: 扩展数据（可选）
func (c *JPushClient) PushToUser(userID int, title, content string, extras map[string]interface{}) error {
	if c == nil {
		LogWarning("极光推送客户端未初始化，跳过推送")
		return nil
	}

	alias := fmt.Sprintf("user_%d", userID)

	msg := &JPushMessage{
		Platform: "all",
		Audience: map[string]interface{}{
			"alias": []string{alias},
		},
		Notification: &JPushNotification{
			Alert: content,
			Android: &JPushAndroidNotify{
				Alert:     content,
				Title:     title,
				ChannelID: "message_channel_v3", // 与客户端通知渠道ID一致
				Priority:  2,                    // 最高优先级
				Category:  "msg",
				AlertType: -1, // 默认提醒方式
				Extras:    extras,
			},
			IOS: &JPushIOSNotify{
				Alert: map[string]string{
					"title": title,
					"body":  content,
				},
				Sound:          "default",
				Badge:          "+1",
				MutableContent: true,
				Extras:         extras,
			},
		},
		Options: &JPushOptions{
			TimeToLive:     86400, // 离线消息保留1天
			ApnsProduction: true,  // iOS 生产环境
		},
	}

	_, err := c.Push(msg)
	if err != nil {
		LogError("推送给用户 %d 失败: %v", userID, err)
		return err
	}

	LogInfo("推送给用户 %d 成功: %s - %s", userID, title, content)
	return nil
}

// PushToUsers 推送给多个用户
func (c *JPushClient) PushToUsers(userIDs []int, title, content string, extras map[string]interface{}) error {
	if c == nil {
		LogWarning("极光推送客户端未初始化，跳过推送")
		return nil
	}

	aliases := make([]string, len(userIDs))
	for i, id := range userIDs {
		aliases[i] = fmt.Sprintf("user_%d", id)
	}

	msg := &JPushMessage{
		Platform: "all",
		Audience: map[string]interface{}{
			"alias": aliases,
		},
		Notification: &JPushNotification{
			Alert: content,
			Android: &JPushAndroidNotify{
				Alert:     content,
				Title:     title,
				ChannelID: "message_channel_v3",
				Priority:  2,
				Category:  "msg",
				AlertType: -1,
				Extras:    extras,
			},
			IOS: &JPushIOSNotify{
				Alert: map[string]string{
					"title": title,
					"body":  content,
				},
				Sound:          "default",
				Badge:          "+1",
				MutableContent: true,
				Extras:         extras,
			},
		},
		Options: &JPushOptions{
			TimeToLive:     86400,
			ApnsProduction: true,
		},
	}

	_, err := c.Push(msg)
	if err != nil {
		LogError("推送给用户 %v 失败: %v", userIDs, err)
		return err
	}

	LogInfo("推送给用户 %v 成功: %s - %s", userIDs, title, content)
	return nil
}

// PushPrivateMessage 推送私聊消息通知
func (c *JPushClient) PushPrivateMessage(receiverID, senderID int, senderName, content, messageType string) error {
	// 格式化消息内容
	displayContent := formatMessageContent(messageType, content)

	extras := map[string]interface{}{
		"type":         "private_message",
		"sender_id":    senderID,
		"message_type": messageType,
	}

	return c.PushToUser(receiverID, senderName, displayContent, extras)
}

// PushGroupMessage 推送群聊消息通知
func (c *JPushClient) PushGroupMessage(receiverIDs []int, senderID, groupID int, groupName, senderName, content, messageType string) error {
	// 格式化消息内容
	displayContent := formatMessageContent(messageType, content)
	title := groupName
	body := fmt.Sprintf("%s: %s", senderName, displayContent)

	extras := map[string]interface{}{
		"type":         "group_message",
		"sender_id":    senderID,
		"group_id":     groupID,
		"message_type": messageType,
	}

	return c.PushToUsers(receiverIDs, title, body, extras)
}

// formatMessageContent 格式化消息内容（根据消息类型）
func formatMessageContent(messageType, content string) string {
	switch messageType {
	case "image":
		return "[图片]"
	case "video":
		return "[视频]"
	case "file":
		return "[文件]"
	case "audio", "voice":
		return "[语音]"
	case "call_ended", "call_ended_video":
		return "[通话结束]"
	default:
		// 限制文本长度
		if len(content) > 100 {
			return content[:100] + "..."
		}
		return content
	}
}
