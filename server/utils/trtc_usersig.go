package utils

import (
	"bytes"
	"compress/zlib"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"time"
)

// TRTCConfig TRTC配置
type TRTCConfig struct {
	SDKAppID  int
	SecretKey string
}

// GenerateUserSig 生成腾讯云 TRTC UserSig
// sdkAppId: 腾讯云 SDKAppID
// secretKey: 腾讯云 SecretKey
// userId: 用户ID（字符串）
// expireTime: 过期时间（秒）
func GenerateUserSig(sdkAppId int, secretKey string, userId string, expireTime int) (string, error) {
	currTime := time.Now().Unix()
	
	// 构建签名内容
	sigDoc := map[string]interface{}{
		"TLS.ver":        "2.0",
		"TLS.identifier": userId,
		"TLS.sdkappid":   sdkAppId,
		"TLS.expire":     expireTime,
		"TLS.time":       currTime,
	}
	
	// 计算签名
	sig := hmacsha256(sdkAppId, secretKey, userId, currTime, int64(expireTime))
	sigDoc["TLS.sig"] = sig
	
	// JSON序列化
	jsonData, err := json.Marshal(sigDoc)
	if err != nil {
		return "", err
	}
	
	// zlib压缩
	var compressed bytes.Buffer
	w := zlib.NewWriter(&compressed)
	w.Write(jsonData)
	w.Close()
	
	// base64编码（URL安全）
	return base64UrlEncode(compressed.Bytes()), nil
}

// hmacsha256 计算HMAC-SHA256签名
func hmacsha256(sdkAppId int, secretKey string, userId string, currTime int64, expire int64) string {
	contentToBeSigned := "TLS.identifier:" + userId + "\n"
	contentToBeSigned += "TLS.sdkappid:" + strconv.Itoa(sdkAppId) + "\n"
	contentToBeSigned += "TLS.time:" + strconv.FormatInt(currTime, 10) + "\n"
	contentToBeSigned += "TLS.expire:" + strconv.FormatInt(expire, 10) + "\n"
	
	h := hmac.New(sha256.New, []byte(secretKey))
	h.Write([]byte(contentToBeSigned))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// base64UrlEncode URL安全的base64编码
func base64UrlEncode(data []byte) string {
	str := base64.StdEncoding.EncodeToString(data)
	str = bytes.NewBufferString(str).String()
	// 替换为URL安全字符
	result := ""
	for _, c := range str {
		switch c {
		case '+':
			result += "*"
		case '/':
			result += "-"
		case '=':
			result += "_"
		default:
			result += string(c)
		}
	}
	return result
}
