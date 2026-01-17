package controllers

import (
	"database/sql"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"youdu-server/models"
	"youdu-server/utils"

	"github.com/aliyun/aliyun-oss-go-sdk/oss"
	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
)

const (
	defaultSignedURLExpiry int64 = 600 // 10分钟，更安全
	maxFileSize            int64 = 5 * 1024 * 1024 * 1024 // 5GB
	maxPartSize            int64 = 100 * 1024 * 1024      // 100MB per part
	minPartSize            int64 = 5 * 1024 * 1024         // 5MB per part
)

// OSSController provides endpoints for client-side multipart uploads.
type OSSController struct{
	DB *sql.DB
}

// NewOSSController creates a new instance of OSSController.
func NewOSSController() *OSSController {
	return &OSSController{}
}

// SetDB sets the database connection for the controller
func (ctrl *OSSController) SetDB(db *sql.DB) {
	ctrl.DB = db
}

type ossContext struct {
	bucket     *oss.Bucket
	endpoint   string
	bucketName string
}

func (ctrl *OSSController) getOSSContext() (*ossContext, error) {
	endpoint := os.Getenv("S3_ENDPOINT")
	if endpoint == "" {
		endpoint = viper.GetString("S3_ENDPOINT")
	}

	accessKey := os.Getenv("S3_ACCESS_KEY")
	if accessKey == "" {
		accessKey = viper.GetString("S3_ACCESS_KEY")
	}

	secretKey := os.Getenv("S3_SECRET_KEY")
	if secretKey == "" {
		secretKey = viper.GetString("S3_SECRET_KEY")
	}

	bucketName := os.Getenv("S3_BUCKET")
	if bucketName == "" {
		bucketName = viper.GetString("S3_BUCKET")
	}

	if endpoint == "" || accessKey == "" || secretKey == "" || bucketName == "" {
		return nil, fmt.Errorf("OSS配置未设置")
	}

	client, err := oss.New(endpoint, accessKey, secretKey)
	if err != nil {
		return nil, fmt.Errorf("创建OSS客户端失败: %w", err)
	}

	bucket, err := client.Bucket(bucketName)
	if err != nil {
		return nil, fmt.Errorf("获取Bucket失败: %w", err)
	}

	return &ossContext{
		bucket:     bucket,
		endpoint:   endpoint,
		bucketName: bucketName,
	}, nil
}

type initiateMultipartRequest struct {
	FileName     string `json:"file_name" binding:"required"`
	FileType     string `json:"file_type" binding:"required"`
	ContentType  string `json:"content_type"`
	FileSize     int64  `json:"file_size" binding:"required"` // 文件总大小，用于验证
	ExpireSecond int64  `json:"expire_seconds"`
}

// InitiateMultipartUpload initializes a multipart upload on OSS and returns the upload ID and a pre-signed URL for the first part.
func (ctrl *OSSController) InitiateMultipartUpload(c *gin.Context) {
	// 🔐 安全控制：获取用户ID（必须登录）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未登录，请先登录")
		return
	}
	userIDInt, ok := userID.(int)
	if !ok {
		utils.Unauthorized(c, "用户ID格式错误")
		return
	}

	var req initiateMultipartRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 🔐 安全控制：验证文件大小
	if req.FileSize <= 0 {
		utils.BadRequest(c, "文件大小必须大于0")
		return
	}
	if req.FileSize > maxFileSize {
		utils.BadRequest(c, fmt.Sprintf("文件大小不能超过 %d MB", maxFileSize/(1024*1024)))
		return
	}

	// 🔐 安全控制：验证文件类型和MIME类型
	baseFileName := filepath.Base(req.FileName)
	ext := strings.ToLower(filepath.Ext(baseFileName))
	if !ctrl.isAllowedFileType(ext, req.FileType) {
		utils.BadRequest(c, fmt.Sprintf("不支持的文件类型: %s", ext))
		return
	}

	// 🔐 安全控制：验证ContentType
	contentType := req.ContentType
	if contentType == "" {
		contentType = detectContentType(baseFileName, req.FileType)
	}
	if contentType != "" && !ctrl.isAllowedMimeType(contentType, req.FileType) {
		utils.BadRequest(c, fmt.Sprintf("不支持的MIME类型: %s", contentType))
		return
	}

	ctx, err := ctrl.getOSSContext()
	if err != nil {
		utils.InternalServerError(c, err.Error())
		return
	}

	folder, err := resolveFolderByType(req.FileType)
	if err != nil {
		utils.BadRequest(c, err.Error())
		return
	}

	// 🔐 安全控制：限制文件路径前缀（使用用户ID）
	// objectKey格式: folder/user/{userID}/timestamp_filename
	objectKey := fmt.Sprintf("%s/user/%d/%d_%s", folder, userIDInt, time.Now().UnixNano(), baseFileName)

	options := []oss.Option{}
	if contentType != "" {
		options = append(options, oss.ContentType(contentType))
	}

	imur, err := ctx.bucket.InitiateMultipartUpload(objectKey, options...)
	if err != nil {
		utils.InternalServerError(c, "初始化分片上传失败: "+err.Error())
		return
	}

	// 🔐 安全控制：限制签名有效期（5-10分钟）
	expire := req.ExpireSecond
	if expire <= 0 {
		expire = defaultSignedURLExpiry
	}
	if expire > 600 { // 最多10分钟
		expire = 600
	}
	if expire < 300 { // 最少5分钟
		expire = 300
	}

	firstPartURL, err := ctx.bucket.SignURL(objectKey, oss.HTTPPut, expire, oss.AddParam("uploadId", imur.UploadID), oss.AddParam("partNumber", "1"))
	if err != nil {
		utils.InternalServerError(c, "生成分片签名URL失败: "+err.Error())
		return
	}

	// 构建文件URL - 优先使用CDN域名
	cdnDomain := os.Getenv("S3_CDN_DOMAIN")
	if cdnDomain == "" {
		cdnDomain = viper.GetString("S3_CDN_DOMAIN")
	}
	var fileURL string
	if cdnDomain != "" {
		fileURL = fmt.Sprintf("https://%s/%s", cdnDomain, objectKey)
	} else {
		endpointHost := strings.TrimPrefix(ctx.endpoint, "https://")
		endpointHost = strings.TrimPrefix(endpointHost, "http://")
		fileURL = fmt.Sprintf("https://%s.%s/%s", ctx.bucketName, endpointHost, objectKey)
	}

	utils.Success(c, gin.H{
		"upload_id":         imur.UploadID,
		"object_key":        objectKey,
		"first_part_url":    firstPartURL,
		"expires_in":        expire,
		"content_type":      contentType,
		"predicted_oss_url": fileURL,
	})
}

type signPartRequest struct {
	UploadID     string `json:"upload_id" binding:"required"`
	ObjectKey    string `json:"object_key" binding:"required"`
	PartNumber   int    `json:"part_number" binding:"required"`
	ExpireSecond int64  `json:"expire_seconds"`
}

// SignMultipartPart generates a signed URL for the specified part number.
func (ctrl *OSSController) SignMultipartPart(c *gin.Context) {
	// 🔐 安全控制：获取用户ID（必须登录）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未登录，请先登录")
		return
	}
	userIDInt, ok := userID.(int)
	if !ok {
		utils.Unauthorized(c, "用户ID格式错误")
		return
	}

	var req signPartRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	if req.PartNumber <= 0 {
		utils.BadRequest(c, "part_number 必须大于 0")
		return
	}

	// 🔐 安全控制：验证objectKey路径（必须包含用户ID）
	if !strings.Contains(req.ObjectKey, fmt.Sprintf("/user/%d/", userIDInt)) {
		utils.BadRequest(c, "objectKey路径不合法")
		return
	}

	ctx, err := ctrl.getOSSContext()
	if err != nil {
		utils.InternalServerError(c, err.Error())
		return
	}

	// 🔐 安全控制：限制签名有效期（5-10分钟）
	expire := req.ExpireSecond
	if expire <= 0 {
		expire = defaultSignedURLExpiry
	}
	if expire > 600 { // 最多10分钟
		expire = 600
	}
	if expire < 300 { // 最少5分钟
		expire = 300
	}

	url, err := ctx.bucket.SignURL(req.ObjectKey, oss.HTTPPut, expire, oss.AddParam("uploadId", req.UploadID), oss.AddParam("partNumber", strconv.Itoa(req.PartNumber)))
	if err != nil {
		utils.InternalServerError(c, "生成分片签名URL失败: "+err.Error())
		return
	}

	utils.Success(c, gin.H{
		"signed_url":  url,
		"expires_in":  expire,
		"part_number": req.PartNumber,
	})
}

type completeMultipartRequest struct {
	UploadID     string `json:"upload_id" binding:"required"`
	ObjectKey    string `json:"object_key" binding:"required"`
	ExpireSecond int64  `json:"expire_seconds"`
}

// CompleteMultipartUpload returns a signed URL that can be used by clients to complete the multipart upload.
func (ctrl *OSSController) CompleteMultipartUpload(c *gin.Context) {
	// 🔐 安全控制：获取用户ID（必须登录）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未登录，请先登录")
		return
	}
	userIDInt, ok := userID.(int)
	if !ok {
		utils.Unauthorized(c, "用户ID格式错误")
		return
	}

	var req completeMultipartRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 🔐 安全控制：验证objectKey路径（必须包含用户ID）
	if !strings.Contains(req.ObjectKey, fmt.Sprintf("/user/%d/", userIDInt)) {
		utils.BadRequest(c, "objectKey路径不合法")
		return
	}

	ctx, err := ctrl.getOSSContext()
	if err != nil {
		utils.InternalServerError(c, err.Error())
		return
	}

	// 🔐 安全控制：限制签名有效期（5-10分钟）
	expire := req.ExpireSecond
	if expire <= 0 {
		expire = defaultSignedURLExpiry
	}
	if expire > 600 { // 最多10分钟
		expire = 600
	}
	if expire < 300 { // 最少5分钟
		expire = 300
	}

	// ⚠️ 重要：CompleteMultipartUpload需要指定Content-Type为application/xml; charset=utf-8
	// 必须与Flutter端发送的Content-Type完全一致，包括charset参数
	url, err := ctx.bucket.SignURL(req.ObjectKey, oss.HTTPPost, expire, 
		oss.AddParam("uploadId", req.UploadID),
		oss.ContentType("application/xml; charset=utf-8"),
	)
	if err != nil {
		utils.InternalServerError(c, "生成完成上传签名URL失败: "+err.Error())
		return
	}

	utils.Success(c, gin.H{
		"signed_url": url,
		"expires_in": expire,
	})
}

func resolveFolderByType(fileType string) (string, error) {
	switch strings.ToLower(fileType) {
	case "image", "images":
		return "images", nil
	case "video", "videos":
		return "videos", nil
	case "audio", "voice":
		return "voice", nil
	case "file", "files":
		return "files", nil
	default:
		return "", fmt.Errorf("不支持的 file_type: %s", fileType)
	}
}

type getOpusUploadURLRequest struct {
	FileName string `json:"fileName" binding:"required"`
}

// GetOpusUploadURL 获取OPUS语音文件的预签名上传URL
// 简化版接口，专门用于语音文件上传
func (ctrl *OSSController) GetOpusUploadURL(c *gin.Context) {
	// 🔐 安全控制：获取用户ID（必须登录）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未登录，请先登录")
		return
	}
	userIDInt, ok := userID.(int)
	if !ok {
		utils.Unauthorized(c, "用户ID格式错误")
		return
	}

	var req getOpusUploadURLRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	// 验证文件扩展名（只允许音频格式）
	baseFileName := filepath.Base(req.FileName)
	ext := strings.ToLower(filepath.Ext(baseFileName))
	allowedExts := []string{".opus", ".ogg", ".webm", ".m4a", ".aac", ".mp3", ".wav", ".amr"}
	isAllowed := false
	for _, allowedExt := range allowedExts {
		if ext == allowedExt {
			isAllowed = true
			break
		}
	}
	if !isAllowed {
		utils.BadRequest(c, fmt.Sprintf("不支持的语音文件类型: %s", ext))
		return
	}

	ctx, err := ctrl.getOSSContext()
	if err != nil {
		utils.InternalServerError(c, err.Error())
		return
	}

	// 生成objectKey: voice/user/{userID}/timestamp_filename
	objectKey := fmt.Sprintf("voice/user/%d/%d_%s", userIDInt, time.Now().UnixNano(), baseFileName)

	// 根据扩展名确定Content-Type
	contentType := "audio/ogg"
	switch ext {
	case ".opus", ".ogg":
		contentType = "audio/ogg"
	case ".webm":
		contentType = "audio/webm"
	case ".m4a", ".aac":
		contentType = "audio/mp4"
	case ".mp3":
		contentType = "audio/mpeg"
	case ".wav":
		contentType = "audio/wav"
	case ".amr":
		contentType = "audio/amr"
	}

	// 签名有效期10分钟
	expire := int64(600)

	// 生成预签名PUT URL
	uploadURL, err := ctx.bucket.SignURL(objectKey, oss.HTTPPut, expire,
		oss.ContentType(contentType),
	)
	if err != nil {
		utils.InternalServerError(c, "生成上传签名URL失败: "+err.Error())
		return
	}

	// 生成文件访问URL - 优先使用CDN域名
	cdnDomain := os.Getenv("S3_CDN_DOMAIN")
	if cdnDomain == "" {
		cdnDomain = viper.GetString("S3_CDN_DOMAIN")
	}
	var fileURL string
	if cdnDomain != "" {
		fileURL = fmt.Sprintf("https://%s/%s", cdnDomain, objectKey)
	} else {
		endpointHost := strings.TrimPrefix(ctx.endpoint, "https://")
		endpointHost = strings.TrimPrefix(endpointHost, "http://")
		fileURL = fmt.Sprintf("https://%s.%s/%s", ctx.bucketName, endpointHost, objectKey)
	}

	utils.Success(c, gin.H{
		"uploadUrl":   uploadURL,
		"fileUrl":     fileURL,
		"contentType": contentType,
		"expiresIn":   expire,
	})
}

func detectContentType(fileName string, fileType string) string {
	ext := strings.ToLower(filepath.Ext(fileName))

	switch strings.ToLower(fileType) {
	case "image", "images":
		switch ext {
		case ".jpg", ".jpeg":
			return "image/jpeg"
		case ".png":
			return "image/png"
		case ".gif":
			return "image/gif"
		case ".webp":
			return "image/webp"
		}
		return "image/jpeg"
	case "video", "videos":
		switch ext {
		case ".mp4":
			return "video/mp4"
		case ".mov":
			return "video/quicktime"
		case ".avi":
			return "video/x-msvideo"
		case ".mkv":
			return "video/x-matroska"
		case ".flv":
			return "video/x-flv"
		case ".wmv":
			return "video/x-ms-wmv"
		case ".webm":
			return "video/webm"
		case ".m4v":
			return "video/mp4"
		}
		return "video/mp4"
	default:
		switch ext {
		case ".pdf":
			return "application/pdf"
		case ".txt":
			return "text/plain"
		case ".doc":
			return "application/msword"
		case ".docx":
			return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
		case ".ppt":
			return "application/vnd.ms-powerpoint"
		case ".pptx":
			return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
		case ".xls":
			return "application/vnd.ms-excel"
		case ".xlsx":
			return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
		}
	}

	return ""
}

// isAllowedFileType 检查文件扩展名是否允许
func (ctrl *OSSController) isAllowedFileType(ext string, fileType string) bool {
	allowedExts := map[string][]string{
		"image":  {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"},
		"images": {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"},
		"video":  {".mp4", ".mov", ".avi", ".mkv", ".flv", ".wmv", ".webm", ".m4v", ".3gp"},
		"videos": {".mp4", ".mov", ".avi", ".mkv", ".flv", ".wmv", ".webm", ".m4v", ".3gp"},
		"audio":  {".mp3", ".wav", ".aac", ".m4a", ".ogg", ".opus", ".flac", ".wma", ".amr"},
		"voice":  {".mp3", ".wav", ".aac", ".m4a", ".ogg", ".opus", ".flac", ".wma", ".amr"},
		"file": {
			".pdf", ".txt", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx",
			".zip", ".rar", ".7z", ".tar", ".gz",
			".apk", ".ipa", ".exe", ".dmg",
		},
		"files": {
			".pdf", ".txt", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx",
			".zip", ".rar", ".7z", ".tar", ".gz",
			".apk", ".ipa", ".exe", ".dmg",
		},
	}

	exts, exists := allowedExts[strings.ToLower(fileType)]
	if !exists {
		return false
	}

	for _, allowedExt := range exts {
		if ext == allowedExt {
			return true
		}
	}
	return false
}

// isAllowedMimeType 检查MIME类型是否允许
func (ctrl *OSSController) isAllowedMimeType(mimeType string, fileType string) bool {
	allowedMimes := map[string][]string{
		"image": {
			"image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/svg+xml",
		},
		"images": {
			"image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/svg+xml",
		},
		"video": {
			"video/mp4", "video/quicktime", "video/x-msvideo", "video/x-matroska",
			"video/x-flv", "video/x-ms-wmv", "video/webm", "video/3gpp",
		},
		"videos": {
			"video/mp4", "video/quicktime", "video/x-msvideo", "video/x-matroska",
			"video/x-flv", "video/x-ms-wmv", "video/webm", "video/3gpp",
		},
		"audio": {
			"audio/mpeg", "audio/wav", "audio/aac", "audio/mp4", "audio/x-m4a",
			"audio/ogg", "audio/opus", "audio/flac", "audio/x-ms-wma", "audio/amr",
		},
		"voice": {
			"audio/mpeg", "audio/wav", "audio/aac", "audio/mp4", "audio/x-m4a",
			"audio/ogg", "audio/opus", "audio/flac", "audio/x-ms-wma", "audio/amr",
		},
		"file": {
			"application/pdf", "text/plain",
			"application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
			"application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
			"application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
			"application/zip", "application/x-rar-compressed", "application/x-7z-compressed",
			"application/x-tar", "application/gzip",
			"application/vnd.android.package-archive", "application/octet-stream",
		},
		"files": {
			"application/pdf", "text/plain",
			"application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
			"application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
			"application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
			"application/zip", "application/x-rar-compressed", "application/x-7z-compressed",
			"application/x-tar", "application/gzip",
			"application/vnd.android.package-archive", "application/octet-stream",
		},
	}

	mimes, exists := allowedMimes[strings.ToLower(fileType)]
	if !exists {
		return false
	}

	// 解析MIME类型（可能包含charset等参数）
	mediaType, _, err := mime.ParseMediaType(mimeType)
	if err != nil {
		// 如果解析失败，直接比较
		mediaType = mimeType
	}

	for _, allowedMime := range mimes {
		if mediaType == allowedMime {
			return true
		}
	}
	return false
}

// GetOSSPrefixConfig 获取OSS前缀域名配置
func (ctrl *OSSController) GetOSSPrefixConfig(c *gin.Context) {
	if ctrl.DB == nil {
		utils.InternalServerError(c, "数据库连接未初始化")
		return
	}

	repo := models.NewOSSPrefixConfigRepository(ctrl.DB)
	config, err := repo.GetConfig()
	if err != nil {
		if err == sql.ErrNoRows {
			utils.NotFound(c, "未找到OSS前缀域名配置")
			return
		}
		utils.InternalServerError(c, "获取OSS前缀域名配置失败: "+err.Error())
		return
	}

	utils.Success(c, gin.H{
		"old_prefix_domain": config.OldPrefixDomain,
		"new_prefix_domain": config.NewPrefixDomain,
	})
}

type updateOSSPrefixConfigRequest struct {
	OldPrefixDomain string `json:"old_prefix_domain" binding:"required"`
	NewPrefixDomain string `json:"new_prefix_domain" binding:"required"`
}

// UpdateOSSPrefixConfig 更新OSS前缀域名配置（管理用）
func (ctrl *OSSController) UpdateOSSPrefixConfig(c *gin.Context) {
	if ctrl.DB == nil {
		utils.InternalServerError(c, "数据库连接未初始化")
		return
	}

	idStr := c.Param("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		utils.BadRequest(c, "无效的配置ID")
		return
	}

	var req updateOSSPrefixConfigRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "请求参数错误: "+err.Error())
		return
	}

	repo := models.NewOSSPrefixConfigRepository(ctrl.DB)
	err = repo.Update(id, req.OldPrefixDomain, req.NewPrefixDomain)
	if err != nil {
		utils.InternalServerError(c, "更新OSS前缀域名配置失败: "+err.Error())
		return
	}

	utils.Success(c, gin.H{
		"message": "更新成功",
	})
}
