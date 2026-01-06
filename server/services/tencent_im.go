package services

import (
	"bytes"
	"compress/zlib"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"

	"youdu-server/config"
	"youdu-server/utils"
)

// TencentIMService 腾讯云 IM 服务
type TencentIMService struct {
	SDKAppID  int
	SecretKey string
	AdminUser string
}

// NewTencentIMService 创建腾讯云 IM 服务实例
func NewTencentIMService() *TencentIMService {
	return &TencentIMService{
		SDKAppID:  config.AppConfig.TRTCSDKAppID,
		SecretKey: config.AppConfig.TRTCSecretKey,
		AdminUser: "administrator",
	}
}

// genUserSig 生成 UserSig (参考官方 Dart 实现)
func (s *TencentIMService) genUserSig(userID string, expire int) (string, error) {
	currTime := time.Now().Unix()

	// 生成签名字符串 (顺序与官方一致)
	sigStr := fmt.Sprintf("TLS.identifier:%s\nTLS.sdkappid:%d\nTLS.time:%d\nTLS.expire:%d\n",
		userID, s.SDKAppID, currTime, expire)

	// HMAC-SHA256 签名
	h := hmac.New(sha256.New, []byte(s.SecretKey))
	h.Write([]byte(sigStr))
	sig := base64.StdEncoding.EncodeToString(h.Sum(nil))

	// 构建 JSON 文档 (顺序与官方一致)
	sigDoc := map[string]interface{}{
		"TLS.ver":        "2.0",
		"TLS.identifier": userID,
		"TLS.sdkappid":   s.SDKAppID,
		"TLS.expire":     expire,
		"TLS.time":       currTime,
		"TLS.sig":        sig,
	}

	// JSON 序列化
	jsonBytes, err := json.Marshal(sigDoc)
	if err != nil {
		return "", err
	}

	// zlib 压缩
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	w.Write(jsonBytes)
	w.Close()

	// Base64 编码后进行字符替换 (与官方一致: + -> *, / -> -, = -> _)
	b64Str := base64.StdEncoding.EncodeToString(buf.Bytes())
	userSig := strings.Replace(b64Str, "+", "*", -1)
	userSig = strings.Replace(userSig, "/", "-", -1)
	userSig = strings.Replace(userSig, "=", "_", -1)

	return userSig, nil
}

// genRandom 生成随机数
func (s *TencentIMService) genRandom() string {
	return strconv.FormatInt(rand.Int63n(10000000000), 10)
}

// IMAPIResponse 腾讯云 IM API 响应
type IMAPIResponse struct {
	ActionStatus string `json:"ActionStatus"`
	ErrorCode    int    `json:"ErrorCode"`
	ErrorInfo    string `json:"ErrorInfo"`
}

// callIMAPI 调用腾讯云 IM API
func (s *TencentIMService) callIMAPI(service, command string, data interface{}) (*IMAPIResponse, error) {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过 API 调用")
		return &IMAPIResponse{ActionStatus: "OK"}, nil
	}

	userSig, err := s.genUserSig(s.AdminUser, 86400*180)
	if err != nil {
		return nil, fmt.Errorf("生成 UserSig 失败: %v", err)
	}

	url := fmt.Sprintf("https://console.tim.qq.com/v4/%s/%s?sdkappid=%d&identifier=%s&usersig=%s&random=%s&contenttype=json",
		service, command, s.SDKAppID, s.AdminUser, userSig, s.genRandom())

	jsonData, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("序列化请求数据失败: %v", err)
	}

	resp, err := http.Post(url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("HTTP 请求失败: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读取响应失败: %v", err)
	}

	var result IMAPIResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("解析响应失败: %v", err)
	}

	return &result, nil
}

// ImportUser 导入用户到腾讯云 IM
func (s *TencentIMService) ImportUser(userID int, nickname, avatar string) error {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过用户导入")
		return nil
	}

	data := map[string]interface{}{
		"UserID":  strconv.Itoa(userID),
		"Nick":    nickname,
		"FaceUrl": avatar,
	}

	result, err := s.callIMAPI("im_open_login_svc", "account_import", data)
	if err != nil {
		utils.LogDebug("❌ 腾讯云 IM 导入用户失败: %v", err)
		return err
	}

	if result.ActionStatus != "OK" {
		utils.LogDebug("❌ 腾讯云 IM 导入用户失败: %s (ErrorCode: %d)", result.ErrorInfo, result.ErrorCode)
		return fmt.Errorf("导入用户失败: %s", result.ErrorInfo)
	}

	utils.LogDebug("✅ 腾讯云 IM 用户导入成功: userID=%d, nickname=%s", userID, nickname)
	return nil
}

// CreateGroup 在腾讯云 IM 创建群组
func (s *TencentIMService) CreateGroup(groupID int, groupName string, ownerID int, memberIDs []int) error {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过群组创建")
		return nil
	}

	// 准备成员列表（不包括群主）
	ownerIDStr := strconv.Itoa(ownerID)
	var memberList []map[string]string
	for _, mid := range memberIDs {
		midStr := strconv.Itoa(mid)
		if midStr != ownerIDStr {
			memberList = append(memberList, map[string]string{
				"Member_Account": midStr,
			})
		}
	}

	// 限制成员数量（最多500个）
	if len(memberList) > 500 {
		memberList = memberList[:500]
	}

	data := map[string]interface{}{
		"Owner_Account": ownerIDStr,
		"Type":          "AVChatRoom", // 音视频聊天室类型，适合通话场景
		"GroupId":       strconv.Itoa(groupID),
		"Name":          groupName,
		"MemberList":    memberList,
	}

	result, err := s.callIMAPI("group_open_http_svc", "create_group", data)
	if err != nil {
		utils.LogDebug("❌ 腾讯云 IM 创建群组失败: %v", err)
		return err
	}

	// ErrorCode 10021 表示群组已存在，不算错误
	if result.ActionStatus != "OK" && result.ErrorCode != 10021 {
		utils.LogDebug("❌ 腾讯云 IM 创建群组失败: %s (ErrorCode: %d)", result.ErrorInfo, result.ErrorCode)
		return fmt.Errorf("创建群组失败: %s", result.ErrorInfo)
	}

	if result.ErrorCode == 10021 {
		utils.LogDebug("⏭️ 腾讯云 IM 群组已存在: groupID=%d", groupID)
	} else {
		utils.LogDebug("✅ 腾讯云 IM 群组创建成功: groupID=%d, groupName=%s", groupID, groupName)
	}

	return nil
}

// AddGroupMember 添加群组成员
func (s *TencentIMService) AddGroupMember(groupID int, memberIDs []int) error {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过添加群成员")
		return nil
	}

	var memberList []map[string]string
	for _, mid := range memberIDs {
		memberList = append(memberList, map[string]string{
			"Member_Account": strconv.Itoa(mid),
		})
	}

	data := map[string]interface{}{
		"GroupId":    strconv.Itoa(groupID),
		"MemberList": memberList,
	}

	result, err := s.callIMAPI("group_open_http_svc", "add_group_member", data)
	if err != nil {
		utils.LogDebug("❌ 腾讯云 IM 添加群成员失败: %v", err)
		return err
	}

	if result.ActionStatus != "OK" {
		utils.LogDebug("❌ 腾讯云 IM 添加群成员失败: %s (ErrorCode: %d)", result.ErrorInfo, result.ErrorCode)
		return fmt.Errorf("添加群成员失败: %s", result.ErrorInfo)
	}

	utils.LogDebug("✅ 腾讯云 IM 添加群成员成功: groupID=%d, memberCount=%d", groupID, len(memberIDs))
	return nil
}

// CheckUserExists 检查用户是否已存在于腾讯云 IM
func (s *TencentIMService) CheckUserExists(userID int) (bool, error) {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过用户检查")
		return true, nil // 未配置时默认返回存在，避免阻塞流程
	}

	data := map[string]interface{}{
		"CheckItem": []map[string]string{
			{"UserID": strconv.Itoa(userID)},
		},
	}

	result, err := s.callIMAPIWithBody("im_open_login_svc", "account_check", data)
	if err != nil {
		utils.LogDebug("❌ 腾讯云 IM 检查用户失败: %v", err)
		return false, err
	}

	// 解析响应中的 ResultItem
	if resultItem, ok := result["ResultItem"].([]interface{}); ok && len(resultItem) > 0 {
		if item, ok := resultItem[0].(map[string]interface{}); ok {
			if accountStatus, ok := item["AccountStatus"].(string); ok {
				exists := accountStatus == "Imported"
				utils.LogDebug("🔍 腾讯云 IM 用户检查: userID=%d, exists=%v", userID, exists)
				return exists, nil
			}
		}
	}

	return false, nil
}

// CheckGroupExists 检查群组是否已存在于腾讯云 IM
func (s *TencentIMService) CheckGroupExists(groupID int) (bool, error) {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过群组检查")
		return true, nil // 未配置时默认返回存在，避免阻塞流程
	}

	data := map[string]interface{}{
		"GroupIdList": []string{strconv.Itoa(groupID)},
	}

	result, err := s.callIMAPIWithBody("group_open_http_svc", "get_group_info", data)
	if err != nil {
		utils.LogDebug("❌ 腾讯云 IM 检查群组失败: %v", err)
		return false, err
	}

	// 解析响应中的 GroupInfo
	if groupInfo, ok := result["GroupInfo"].([]interface{}); ok && len(groupInfo) > 0 {
		if info, ok := groupInfo[0].(map[string]interface{}); ok {
			// 如果 ErrorCode 为 0，表示群组存在
			if errorCode, ok := info["ErrorCode"].(float64); ok {
				exists := errorCode == 0
				utils.LogDebug("🔍 腾讯云 IM 群组检查: groupID=%d, exists=%v", groupID, exists)
				return exists, nil
			}
		}
	}

	return false, nil
}

// EnsureUserExists 确保用户存在于腾讯云 IM（不存在则创建）
func (s *TencentIMService) EnsureUserExists(userID int, nickname, avatar string) error {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		return nil
	}

	exists, err := s.CheckUserExists(userID)
	if err != nil {
		utils.LogDebug("⚠️ 检查用户是否存在失败，尝试直接导入: %v", err)
		// 检查失败时尝试直接导入
		return s.ImportUser(userID, nickname, avatar)
	}

	if !exists {
		utils.LogDebug("📝 用户 %d 不存在于腾讯云 IM，开始导入...", userID)
		return s.ImportUser(userID, nickname, avatar)
	}

	utils.LogDebug("✅ 用户 %d 已存在于腾讯云 IM", userID)
	return nil
}

// EnsureGroupExists 确保群组存在于腾讯云 IM（不存在则创建）
func (s *TencentIMService) EnsureGroupExists(groupID int, groupName string, ownerID int, memberIDs []int) error {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		return nil
	}

	exists, err := s.CheckGroupExists(groupID)
	if err != nil {
		utils.LogDebug("⚠️ 检查群组是否存在失败，尝试直接创建: %v", err)
		// 检查失败时尝试直接创建
		return s.CreateGroup(groupID, groupName, ownerID, memberIDs)
	}

	if !exists {
		utils.LogDebug("📝 群组 %d 不存在于腾讯云 IM，开始创建...", groupID)
		return s.CreateGroup(groupID, groupName, ownerID, memberIDs)
	}

	utils.LogDebug("✅ 群组 %d 已存在于腾讯云 IM", groupID)
	return nil
}

// callIMAPIWithBody 调用腾讯云 IM API 并返回完整响应体
func (s *TencentIMService) callIMAPIWithBody(service, command string, data interface{}) (map[string]interface{}, error) {
	if s.SDKAppID == 0 || s.SecretKey == "" {
		utils.LogDebug("⚠️ 腾讯云 IM 未配置，跳过 API 调用")
		return map[string]interface{}{"ActionStatus": "OK"}, nil
	}

	userSig, err := s.genUserSig(s.AdminUser, 86400*180)
	if err != nil {
		return nil, fmt.Errorf("生成 UserSig 失败: %v", err)
	}

	url := fmt.Sprintf("https://console.tim.qq.com/v4/%s/%s?sdkappid=%d&identifier=%s&usersig=%s&random=%s&contenttype=json",
		service, command, s.SDKAppID, s.AdminUser, userSig, s.genRandom())

	jsonData, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("序列化请求数据失败: %v", err)
	}

	resp, err := http.Post(url, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("HTTP 请求失败: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("读取响应失败: %v", err)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("解析响应失败: %v", err)
	}

	return result, nil
}

// 全局实例
var TencentIM *TencentIMService

// InitTencentIM 初始化腾讯云 IM 服务
func InitTencentIM() {
	TencentIM = NewTencentIMService()
	if TencentIM.SDKAppID > 0 && TencentIM.SecretKey != "" {
		utils.LogDebug("✅ 腾讯云 IM 服务已初始化: SDKAppID=%d", TencentIM.SDKAppID)
	} else {
		utils.LogDebug("⚠️ 腾讯云 IM 服务未配置，相关功能将被跳过")
	}
}
