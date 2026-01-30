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

	// 规范化平台名称（统一转换为小写，但查询时使用大小写不敏感）
	// iOS 客户端可能发送 "ios"，但数据库中可能是 "iOS"
	platformLower := strings.ToLower(platform)
	fmt.Printf("🔍 [版本检查] 规范化平台名称: %s -> %s\n", platform, platformLower)

	// 查询该平台最新的已发布版本（使用大小写不敏感查询）
	var latestVersion AppVersion
	err := db.DB.QueryRow(`
		SELECT id, version, platform, distribution_type, package_url, oss_object_key,
		       release_notes, status, is_force_update, min_supported_version,
		       file_size, file_hash, created_at, updated_at, published_at, created_by
		FROM app_versions 
		WHERE LOWER(platform) = $1 AND status = 'published'
		ORDER BY created_at DESC 
		LIMIT 1
	`, platformLower).Scan(
		&latestVersion.ID, &latestVersion.Version, &latestVersion.Platform,
		&latestVersion.DistributionType, &latestVersion.PackageURL, &latestVersion.OSSObjectKey,
		&latestVersion.ReleaseNotes, &latestVersion.Status, &latestVersion.IsForceUpdate,
		&latestVersion.MinSupportedVersion, &latestVersion.FileSize, &latestVersion.FileHash,
		&latestVersion.CreatedAt, &latestVersion.UpdatedAt, &latestVersion.PublishedAt,
		&latestVersion.CreatedBy,
	)

	if err == sql.ErrNoRows {
		fmt.Printf("ℹ️ [版本检查] 平台 %s (规范化: %s) 没有找到活跃版本\n", platform, platformLower)
		c.JSON(http.StatusOK, VersionCheckResponse{HasUpdate: false})
		return
	}
	if err != nil {
		fmt.Printf("❌ [版本检查] 查询失败: %v\n", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("查询版本失败: %v", err)})
		return
	}
	
	fmt.Printf("🔍 [版本检查] 查询到版本记录: ID=%d, Version=%s, Platform=%s, Status=%s\n", 
		latestVersion.ID, latestVersion.Version, latestVersion.Platform, latestVersion.Status)

	// 比较版本号（使用语义化版本号比较，包含 buildNumber）
	// 保存原始版本号（可能包含 buildNumber，如 "1.0.5+7"）
	latestVersionOriginal := latestVersion.Version
	fmt.Printf("🔍 [版本检查] 数据库原始版本: %s\n", latestVersionOriginal)
	
	// 将latestVersion.Version的"v1.0-6.1"格式转换为"1.0.6"（用于显示和返回）
	latestVersion.Version = normalizeVersionFormat(latestVersion.Version)
	fmt.Printf("🔍 [版本检查] 规范化后版本（用于显示）: %s\n", latestVersion.Version)
	
	currentVersion = strings.TrimPrefix(currentVersion, "v")
	fmt.Printf("🔍 [版本检查] 客户端当前版本: %s, 版本代码: %s\n", currentVersion, versionCode)
	
	// 组合当前版本号和 buildNumber（如果提供了 version_code）
	currentVersionFull := currentVersion
	if versionCode != "" {
		// 如果 version_code 不为空，组合成 "version+buildNumber" 格式
		// 注意：即使 version_code 与 current_version 相同，也要组合（因为可能是不同的含义）
		currentVersionFull = fmt.Sprintf("%s+%s", currentVersion, versionCode)
	}
	fmt.Printf("🔍 [版本检查] 客户端完整版本: %s\n", currentVersionFull)
	
	// 使用原始版本号进行比较（可能包含 buildNumber）
	// 去掉 "v" 前缀（不区分大小写）
	latestVersionFull := strings.TrimSpace(latestVersionOriginal)
	if strings.HasPrefix(strings.ToLower(latestVersionFull), "v") {
		latestVersionFull = latestVersionFull[1:]
		latestVersionFull = strings.TrimSpace(latestVersionFull)
	}
	fmt.Printf("🔍 [版本检查] 服务器完整版本（去v后）: %s\n", latestVersionFull)
	
	// 如果原始版本号不包含 + 或 - 分隔符，说明没有 buildNumber
	// 使用规范化后的版本号（buildNumber 视为 0）
	if !strings.Contains(latestVersionFull, "+") && !strings.Contains(latestVersionFull, "-") {
		fmt.Printf("🔍 [版本检查] 服务器版本不包含buildNumber，使用规范化版本: %s\n", latestVersion.Version)
		latestVersionFull = latestVersion.Version
	}
	
	fmt.Printf("🔍 [版本检查] 最终比较: 服务器=%s vs 客户端=%s\n", latestVersionFull, currentVersionFull)
	compareResult := compareVersionStringWithBuild(latestVersionFull, currentVersionFull)
	fmt.Printf("🔍 [版本检查] 比较结果: %d (1=有新版本, 0=相同, -1=客户端更新)\n", compareResult)
	hasUpdate := compareResult > 0

	if !hasUpdate {
		fmt.Printf("ℹ️ [版本检查] 当前版本 %s (完整: %s) 已是最新 (服务器版本: %s, 完整: %s)\n", 
			currentVersion, currentVersionFull, latestVersion.Version, latestVersionFull)
		c.JSON(http.StatusOK, VersionCheckResponse{HasUpdate: false})
		return
	}

	fmt.Printf("✅ [版本检查] 发现新版本: %s (完整: %s) (当前: %s, 完整: %s)\n", 
		latestVersion.Version, latestVersionFull, currentVersion, currentVersionFull)

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

// normalizeVersionFormat 将版本格式从 "v1.0-6.1" 转换为 "1.0.6"
// 支持格式：
//   - "v1.0-6.1" -> "1.0.6" (iOS特殊格式)
//   - "1.0-6.1" -> "1.0.6"
//   - "1.0-6" -> "1.0.6" (构建号没有小数部分)
//   - "1.0.5" -> "1.0.5" (标准格式保持不变)
//   - "1.0.6+1" -> "1.0.6" (标准格式，去掉构建号)
//   - "v1.0.6+1" -> "1.0.6" (标准格式，去掉构建号)
//   - "1.0.6-1" -> "1.0.6" (标准格式，去掉构建号)
//   - "v1.0.6-1" -> "1.0.6" (标准格式，去掉构建号)
func normalizeVersionFormat(version string) string {
	// 去掉 "v" 前缀（不区分大小写）
	version = strings.TrimSpace(version)
	if strings.HasPrefix(strings.ToLower(version), "v") {
		version = version[1:]
		version = strings.TrimSpace(version)
	}
	
	// 先检查标准格式：x.y.z+/-build（三段式版本号后跟构建号）
	// 检查 "+" 分隔符
	if strings.Contains(version, "+") {
		parts := strings.Split(version, "+")
		if len(parts) == 2 {
			mainVersion := strings.TrimSpace(parts[0])
			// 检查主版本号是否是三段式（x.y.z）
			mainParts := strings.Split(mainVersion, ".")
			if len(mainParts) >= 3 {
				// 标准格式，去掉构建号，返回主版本号
				return mainVersion
			}
		}
	}
	
	// 检查 "-" 分隔符
	if strings.Contains(version, "-") {
		parts := strings.Split(version, "-")
		if len(parts) == 2 {
			mainVersion := strings.TrimSpace(parts[0])
			buildPart := strings.TrimSpace(parts[1])
			
			// 检查主版本号是否是三段式（x.y.z）
			mainParts := strings.Split(mainVersion, ".")
			if len(mainParts) >= 3 {
				// 标准格式 x.y.z-build，去掉构建号，返回主版本号
				return mainVersion
			}
			
			// 否则是 iOS 特殊格式 x.y-z.w 或 x.y-z
			if buildPart == "" {
				// 构建号为空，返回原格式
				return version
			}
			
			// 取构建号的第一个数字部分（如 "6.1" -> "6", "6" -> "6"）
			buildParts := strings.Split(buildPart, ".")
			buildNumber := buildParts[0]
			if buildNumber == "" {
				// 构建号格式异常，返回原格式
				return version
			}
			
			// 解析主版本号（iOS特殊格式：x.y）
			if len(mainParts) >= 2 {
				// 主版本号是 "x.y" 格式，组合成 "x.y.buildNumber"
				return fmt.Sprintf("%s.%s.%s", mainParts[0], mainParts[1], buildNumber)
			} else if len(mainParts) == 1 && mainParts[0] != "" {
				// 主版本号是单个数字，组合成 "x.0.buildNumber"
				return fmt.Sprintf("%s.0.%s", mainParts[0], buildNumber)
			}
		}
	}
	
	// 如果不是特殊格式，直接返回（可能是标准格式 "1.0.5"）
	return version
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

// compareVersionStringWithBuild 比较包含 buildNumber 的语义化版本号
// 支持格式: "1.0.5+6" 或 "1.0.5" (没有 buildNumber 时视为 0)
// 比较规则：先比较主版本号，如果相同再比较 buildNumber
// 返回: 1 表示 v1 > v2, -1 表示 v1 < v2, 0 表示 v1 == v2
func compareVersionStringWithBuild(v1, v2 string) int {
	// 解析版本号和 buildNumber
	v1Main, v1Build := parseVersionWithBuild(v1)
	v2Main, v2Build := parseVersionWithBuild(v2)
	
	// 先比较主版本号
	mainCompare := compareVersionString(v1Main, v2Main)
	if mainCompare != 0 {
		return mainCompare
	}
	
	// 主版本号相同，比较 buildNumber
	if v1Build > v2Build {
		return 1
	} else if v1Build < v2Build {
		return -1
	}
	return 0
}

// parseVersionWithBuild 解析版本号，分离主版本号和 buildNumber
// 支持格式: "1.0.5+6" 或 "1.0.5" (没有 buildNumber 时返回 0)
// 返回: (主版本号, buildNumber)
func parseVersionWithBuild(version string) (string, int) {
	version = strings.TrimSpace(version)
	fmt.Printf("🔍 [版本解析] 解析版本号: %s\n", version)
	
	// 检查是否有 + 分隔符（Flutter pubspec.yaml 格式）
	if strings.Contains(version, "+") {
		parts := strings.Split(version, "+")
		if len(parts) == 2 {
			mainVersion := strings.TrimSpace(parts[0])
			buildStr := strings.TrimSpace(parts[1])
			buildNum, err := strconv.Atoi(buildStr)
			if err == nil {
				fmt.Printf("🔍 [版本解析] 解析结果: 主版本=%s, buildNumber=%d\n", mainVersion, buildNum)
				return mainVersion, buildNum
			} else {
				fmt.Printf("⚠️ [版本解析] buildNumber 解析失败: %s, 错误: %v\n", buildStr, err)
			}
		} else {
			fmt.Printf("⚠️ [版本解析] + 分隔符分割后部分数量不正确: %d\n", len(parts))
		}
	}
	
	// 检查是否有 - 分隔符（其他格式）
	if strings.Contains(version, "-") {
		parts := strings.Split(version, "-")
		if len(parts) == 2 {
			mainVersion := strings.TrimSpace(parts[0])
			buildStr := strings.TrimSpace(parts[1])
			// 尝试提取数字部分（如 "6.1" -> "6"）
			buildParts := strings.Split(buildStr, ".")
			if len(buildParts) > 0 {
				buildNum, err := strconv.Atoi(buildParts[0])
				if err == nil {
					return mainVersion, buildNum
				}
			}
		}
	}
	
	// 没有 buildNumber，返回主版本号和 0
	fmt.Printf("🔍 [版本解析] 未找到 buildNumber，返回: 主版本=%s, buildNumber=0\n", version)
	return version, 0
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
