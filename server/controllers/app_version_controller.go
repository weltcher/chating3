package controllers

import (
	"database/sql"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"youdu-server/db"
)

// AppVersionController 应用版本控制器
type AppVersionController struct{}

// NewAppVersionController 创建应用版本控制器
func NewAppVersionController() *AppVersionController {
	return &AppVersionController{}
}

// AppVersion 应用版本信息（匹配数据库表结构）
type AppVersion struct {
	ID                   int            `json:"id"`
	Version              string         `json:"version"`
	Platform             string         `json:"platform"`
	DistributionType     sql.NullString `json:"distribution_type"`
	PackageURL           sql.NullString `json:"package_url"`
	OSSObjectKey         sql.NullString `json:"oss_object_key"`
	ReleaseNotes         sql.NullString `json:"release_notes"`
	Status               string         `json:"status"`
	IsForceUpdate        bool           `json:"is_force_update"`
	MinSupportedVersion  sql.NullString `json:"min_supported_version"`
	FileSize             int64          `json:"file_size"`
	FileHash             sql.NullString `json:"file_hash"`
	CreatedAt            time.Time      `json:"created_at"`
	UpdatedAt            time.Time      `json:"updated_at"`
	PublishedAt          sql.NullTime   `json:"published_at"`
	CreatedBy            sql.NullString `json:"created_by"`
}

// VersionCheckResponse 版本检查响应
type VersionCheckResponse struct {
	HasUpdate  bool                `json:"has_update"`
	UpdateInfo *VersionUpdateInfo  `json:"update_info,omitempty"`
}

// VersionUpdateInfo 更新信息（返回给客户端）
type VersionUpdateInfo struct {
	Version      string `json:"version"`
	VersionCode  string `json:"version_code"`  // 客户端期望的字段名
	DownloadURL  string `json:"download_url"`  // 客户端期望的字段名
	ReleaseNotes string `json:"release_notes"`
	FileSize     int64  `json:"file_size"`
	MD5          string `json:"md5"`           // 客户端期望的字段名
	ForceUpdate  bool   `json:"force_update"`  // 客户端期望的字段名
	ReleaseDate  string `json:"release_date"`
}

// CheckUpdate 检查版本更新
func (ctrl *AppVersionController) CheckUpdate(c *gin.Context) {
	platform := c.Query("platform")
	currentVersion := c.Query("current_version")
	versionCode := c.Query("version_code")

	fmt.Printf("🔍 [版本检查] 平台: %s, 当前版本: %s, 版本代码: %s\n", platform, currentVersion, versionCode)

	if platform == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少platform参数"})
		return
	}

	// 查询该平台最新的已发布版本
	var latestVersion AppVersion
	err := db.DB.QueryRow(`
		SELECT id, version, platform, distribution_type, package_url, oss_object_key,
		       release_notes, status, is_force_update, min_supported_version,
		       file_size, file_hash, created_at, updated_at, published_at, created_by
		FROM app_versions 
		WHERE platform = $1 AND status = 'published'
		ORDER BY created_at DESC 
		LIMIT 1
	`, platform).Scan(
		&latestVersion.ID, &latestVersion.Version, &latestVersion.Platform,
		&latestVersion.DistributionType, &latestVersion.PackageURL, &latestVersion.OSSObjectKey,
		&latestVersion.ReleaseNotes, &latestVersion.Status, &latestVersion.IsForceUpdate,
		&latestVersion.MinSupportedVersion, &latestVersion.FileSize, &latestVersion.FileHash,
		&latestVersion.CreatedAt, &latestVersion.UpdatedAt, &latestVersion.PublishedAt,
		&latestVersion.CreatedBy,
	)

	if err == sql.ErrNoRows {
		fmt.Printf("ℹ️ [版本检查] 平台 %s 没有找到活跃版本\n", platform)
		c.JSON(http.StatusOK, VersionCheckResponse{HasUpdate: false})
		return
	}
	if err != nil {
		fmt.Printf("❌ [版本检查] 查询失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("查询版本失败: %v", err)})
		return
	}

	// 比较版本号（使用语义化版本号比较）
	hasUpdate := compareVersionString(latestVersion.Version, currentVersion) > 0

	if !hasUpdate {
		fmt.Printf("ℹ️ [版本检查] 当前版本 %s 已是最新 (服务器版本: %s)\n", currentVersion, latestVersion.Version)
		c.JSON(http.StatusOK, VersionCheckResponse{HasUpdate: false})
		return
	}

	fmt.Printf("✅ [版本检查] 发现新版本: %s (当前: %s)\n", latestVersion.Version, currentVersion)

	// 构造返回信息
	releaseDate := ""
	if latestVersion.PublishedAt.Valid {
		releaseDate = latestVersion.PublishedAt.Time.Format("2006-01-02T15:04:05Z07:00")
	} else {
		releaseDate = latestVersion.CreatedAt.Format("2006-01-02T15:04:05Z07:00")
	}

	// 转换 sql.NullString 为普通 string
	packageURL := ""
	if latestVersion.PackageURL.Valid {
		packageURL = latestVersion.PackageURL.String
	}

	releaseNotes := ""
	if latestVersion.ReleaseNotes.Valid {
		releaseNotes = latestVersion.ReleaseNotes.String
	}

	fileHash := ""
	if latestVersion.FileHash.Valid {
		fileHash = latestVersion.FileHash.String
	}

	c.JSON(http.StatusOK, VersionCheckResponse{
		HasUpdate: true,
		UpdateInfo: &VersionUpdateInfo{
			Version:      latestVersion.Version,
			VersionCode:  latestVersion.Version, // 使用version作为version_code
			DownloadURL:  packageURL,
			ReleaseNotes: releaseNotes,
			FileSize:     latestVersion.FileSize,
			MD5:          fileHash,
			ForceUpdate:  latestVersion.IsForceUpdate,
			ReleaseDate:  releaseDate,
		},
	})
}

// compareVersion 比较版本代码，返回 true 表示 v1 > v2
func compareVersion(v1, v2 string) bool {
	code1, _ := strconv.Atoi(v1)
	code2, _ := strconv.Atoi(v2)
	return code1 > code2
}

// compareVersionString 比较语义化版本号
// 支持格式: "1.0.2" 或 "1.0.2-1765514379"
func compareVersionString(v1, v2 string) int {
	// 去掉版本号中的 build number 部分（-后面的内容）
	v1Clean := strings.Split(v1, "-")[0]
	v2Clean := strings.Split(v2, "-")[0]

	parts1 := strings.Split(v1Clean, ".")
	parts2 := strings.Split(v2Clean, ".")

	maxLen := len(parts1)
	if len(parts2) > maxLen {
		maxLen = len(parts2)
	}

	for i := 0; i < maxLen; i++ {
		var num1, num2 int
		if i < len(parts1) {
			num1, _ = strconv.Atoi(parts1[i])
		}
		if i < len(parts2) {
			num2, _ = strconv.Atoi(parts2[i])
		}

		if num1 > num2 {
			return 1
		} else if num1 < num2 {
			return -1
		}
	}
	return 0
}

// GetLatestVersion 获取指定平台最新版本
func (ctrl *AppVersionController) GetLatestVersion(c *gin.Context) {
	platform := c.Query("platform")
	if platform == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少platform参数"})
		return
	}

	var version AppVersion
	err := db.DB.QueryRow(`
		SELECT id, version, platform, distribution_type, package_url, oss_object_key,
		       release_notes, status, is_force_update, min_supported_version,
		       file_size, file_hash, created_at, updated_at, published_at, created_by
		FROM app_versions 
		WHERE platform = $1 AND status = 'published'
		ORDER BY created_at DESC 
		LIMIT 1
	`, platform).Scan(
		&version.ID, &version.Version, &version.Platform,
		&version.DistributionType, &version.PackageURL, &version.OSSObjectKey,
		&version.ReleaseNotes, &version.Status, &version.IsForceUpdate,
		&version.MinSupportedVersion, &version.FileSize, &version.FileHash,
		&version.CreatedAt, &version.UpdatedAt, &version.PublishedAt,
		&version.CreatedBy,
	)

	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "未找到版本信息"})
		return
	}
	if err != nil {
		fmt.Printf("❌ [获取最新版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版本失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"version": version})
}

// GetAllPlatformLatestVersions 获取所有平台最新版本
func (ctrl *AppVersionController) GetAllPlatformLatestVersions(c *gin.Context) {
	platforms := []string{"windows", "macos", "linux", "android", "ios"}
	result := make(map[string]*AppVersion)

	for _, platform := range platforms {
		var version AppVersion
		err := db.DB.QueryRow(`
			SELECT id, version, platform, distribution_type, package_url, oss_object_key,
			       release_notes, status, is_force_update, min_supported_version,
			       file_size, file_hash, created_at, updated_at, published_at, created_by
			FROM app_versions 
			WHERE platform = $1 AND status = 'published'
			ORDER BY created_at DESC 
			LIMIT 1
		`, platform).Scan(
			&version.ID, &version.Version, &version.Platform,
			&version.DistributionType, &version.PackageURL, &version.OSSObjectKey,
			&version.ReleaseNotes, &version.Status, &version.IsForceUpdate,
			&version.MinSupportedVersion, &version.FileSize, &version.FileHash,
			&version.CreatedAt, &version.UpdatedAt, &version.PublishedAt,
			&version.CreatedBy,
		)
		if err == nil {
			result[platform] = &version
		}
	}

	c.JSON(http.StatusOK, gin.H{"versions": result})
}

// CreateVersion 创建新版本
func (ctrl *AppVersionController) CreateVersion(c *gin.Context) {
	var input struct {
		Platform         string `json:"platform" binding:"required"`
		Version          string `json:"version" binding:"required"`
		PackageURL       string `json:"package_url" binding:"required"`
		DistributionType string `json:"distribution_type"`
		OSSObjectKey     string `json:"oss_object_key"`
		ReleaseNotes     string `json:"release_notes"`
		FileSize         int64  `json:"file_size"`
		FileHash         string `json:"file_hash"`
		IsForceUpdate    bool   `json:"is_force_update"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的请求参数"})
		return
	}

	// 默认分发类型为url
	if input.DistributionType == "" {
		input.DistributionType = "url"
	}

	now := time.Now()
	var id int
	err := db.DB.QueryRow(`
		INSERT INTO app_versions (version, platform, distribution_type, package_url, oss_object_key,
		                          release_notes, status, is_force_update, file_size, file_hash,
		                          created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, 'draft', $7, $8, $9, $10, $10)
		RETURNING id
	`, input.Version, input.Platform, input.DistributionType, input.PackageURL, input.OSSObjectKey,
		input.ReleaseNotes, input.IsForceUpdate, input.FileSize, input.FileHash, now).Scan(&id)

	if err != nil {
		fmt.Printf("❌ [创建版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建版本失败: " + err.Error()})
		return
	}

	fmt.Printf("✅ [创建版本] 成功: ID=%d, 平台=%s, 版本=%s\n", id, input.Platform, input.Version)
	c.JSON(http.StatusOK, gin.H{
		"message": "版本创建成功",
		"id":      id,
	})
}

// ListVersions 获取版本列表
func (ctrl *AppVersionController) ListVersions(c *gin.Context) {
	platform := c.Query("platform")
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	offset := (page - 1) * pageSize

	var rows *sql.Rows
	var err error
	var total int

	if platform != "" {
		db.DB.QueryRow("SELECT COUNT(*) FROM app_versions WHERE platform = $1", platform).Scan(&total)
		rows, err = db.DB.Query(`
			SELECT id, version, platform, distribution_type, package_url, oss_object_key,
			       release_notes, status, is_force_update, min_supported_version,
			       file_size, file_hash, created_at, updated_at, published_at, created_by
			FROM app_versions 
			WHERE platform = $1
			ORDER BY created_at DESC 
			LIMIT $2 OFFSET $3
		`, platform, pageSize, offset)
	} else {
		db.DB.QueryRow("SELECT COUNT(*) FROM app_versions").Scan(&total)
		rows, err = db.DB.Query(`
			SELECT id, version, platform, distribution_type, package_url, oss_object_key,
			       release_notes, status, is_force_update, min_supported_version,
			       file_size, file_hash, created_at, updated_at, published_at, created_by
			FROM app_versions 
			ORDER BY created_at DESC 
			LIMIT $1 OFFSET $2
		`, pageSize, offset)
	}

	if err != nil {
		fmt.Printf("❌ [获取版本列表] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版本列表失败"})
		return
	}
	defer rows.Close()

	var versions []AppVersion
	for rows.Next() {
		var v AppVersion
		rows.Scan(
			&v.ID, &v.Version, &v.Platform,
			&v.DistributionType, &v.PackageURL, &v.OSSObjectKey,
			&v.ReleaseNotes, &v.Status, &v.IsForceUpdate,
			&v.MinSupportedVersion, &v.FileSize, &v.FileHash,
			&v.CreatedAt, &v.UpdatedAt, &v.PublishedAt,
			&v.CreatedBy,
		)
		versions = append(versions, v)
	}

	c.JSON(http.StatusOK, gin.H{
		"versions":  versions,
		"total":     total,
		"page":      page,
		"page_size": pageSize,
	})
}

// GetVersion 获取版本详情
func (ctrl *AppVersionController) GetVersion(c *gin.Context) {
	id := c.Param("id")

	var version AppVersion
	err := db.DB.QueryRow(`
		SELECT id, version, platform, distribution_type, package_url, oss_object_key,
		       release_notes, status, is_force_update, min_supported_version,
		       file_size, file_hash, created_at, updated_at, published_at, created_by
		FROM app_versions WHERE id = $1
	`, id).Scan(
		&version.ID, &version.Version, &version.Platform,
		&version.DistributionType, &version.PackageURL, &version.OSSObjectKey,
		&version.ReleaseNotes, &version.Status, &version.IsForceUpdate,
		&version.MinSupportedVersion, &version.FileSize, &version.FileHash,
		&version.CreatedAt, &version.UpdatedAt, &version.PublishedAt,
		&version.CreatedBy,
	)

	if err == sql.ErrNoRows {
		c.JSON(http.StatusNotFound, gin.H{"error": "版本不存在"})
		return
	}
	if err != nil {
		fmt.Printf("❌ [获取版本详情] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询版本失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"version": version})
}

// UpdateVersion 更新版本信息
func (ctrl *AppVersionController) UpdateVersion(c *gin.Context) {
	id := c.Param("id")

	var input struct {
		Version         string `json:"version"`
		PackageURL      string `json:"package_url"`
		ReleaseNotes    string `json:"release_notes"`
		FileSize        int64  `json:"file_size"`
		FileHash        string `json:"file_hash"`
		IsForceUpdate   *bool  `json:"is_force_update"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的请求参数"})
		return
	}

	_, err := db.DB.Exec(`
		UPDATE app_versions SET 
			version = COALESCE(NULLIF($1, ''), version),
			package_url = COALESCE(NULLIF($2, ''), package_url),
			release_notes = COALESCE(NULLIF($3, ''), release_notes),
			file_size = CASE WHEN $4 > 0 THEN $4 ELSE file_size END,
			file_hash = COALESCE(NULLIF($5, ''), file_hash),
			is_force_update = COALESCE($6, is_force_update),
			updated_at = NOW()
		WHERE id = $7
	`, input.Version, input.PackageURL, input.ReleaseNotes,
		input.FileSize, input.FileHash, input.IsForceUpdate, id)

	if err != nil {
		fmt.Printf("❌ [更新版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新版本失败"})
		return
	}

	fmt.Printf("✅ [更新版本] 成功: ID=%s\n", id)
	c.JSON(http.StatusOK, gin.H{"message": "版本更新成功"})
}

// PublishVersion 发布版本
func (ctrl *AppVersionController) PublishVersion(c *gin.Context) {
	id := c.Param("id")

	_, err := db.DB.Exec(`
		UPDATE app_versions 
		SET status = 'published', published_at = NOW(), updated_at = NOW() 
		WHERE id = $1
	`, id)

	if err != nil {
		fmt.Printf("❌ [发布版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "发布版本失败"})
		return
	}

	fmt.Printf("✅ [发布版本] 成功: ID=%s\n", id)
	c.JSON(http.StatusOK, gin.H{"message": "版本发布成功"})
}

// DeprecateVersion 废弃版本
func (ctrl *AppVersionController) DeprecateVersion(c *gin.Context) {
	id := c.Param("id")

	_, err := db.DB.Exec(`
		UPDATE app_versions SET status = 'deprecated', updated_at = NOW() WHERE id = $1
	`, id)

	if err != nil {
		fmt.Printf("❌ [废弃版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "废弃版本失败"})
		return
	}

	fmt.Printf("✅ [废弃版本] 成功: ID=%s\n", id)
	c.JSON(http.StatusOK, gin.H{"message": "版本已废弃"})
}

// DeleteVersion 删除版本
func (ctrl *AppVersionController) DeleteVersion(c *gin.Context) {
	id := c.Param("id")

	_, err := db.DB.Exec("DELETE FROM app_versions WHERE id = $1", id)
	if err != nil {
		fmt.Printf("❌ [删除版本] 失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除版本失败"})
		return
	}

	fmt.Printf("✅ [删除版本] 成功: ID=%s\n", id)
	c.JSON(http.StatusOK, gin.H{"message": "版本删除成功"})
}
