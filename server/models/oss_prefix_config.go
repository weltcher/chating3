package models

import (
	"database/sql"
	"time"
)

// OSSPrefixConfig OSS前缀域名配置模型
type OSSPrefixConfig struct {
	ID              int       `json:"id"`
	OldPrefixDomain string    `json:"old_prefix_domain"`
	NewPrefixDomain string    `json:"new_prefix_domain"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// OSSPrefixConfigRepository OSS前缀域名配置数据仓库
type OSSPrefixConfigRepository struct {
	DB *sql.DB
}

// NewOSSPrefixConfigRepository 创建OSS前缀域名配置仓库
func NewOSSPrefixConfigRepository(db *sql.DB) *OSSPrefixConfigRepository {
	return &OSSPrefixConfigRepository{DB: db}
}

// GetConfig 获取配置（只有一条记录）
func (r *OSSPrefixConfigRepository) GetConfig() (*OSSPrefixConfig, error) {
	query := `
		SELECT id, old_prefix_domain, new_prefix_domain, created_at, updated_at
		FROM oss_prefix_config
		ORDER BY id DESC
		LIMIT 1
	`

	config := &OSSPrefixConfig{}
	err := r.DB.QueryRow(query).Scan(
		&config.ID,
		&config.OldPrefixDomain,
		&config.NewPrefixDomain,
		&config.CreatedAt,
		&config.UpdatedAt,
	)

	if err != nil {
		return nil, err
	}

	return config, nil
}

// Update 更新配置
func (r *OSSPrefixConfigRepository) Update(id int, oldPrefix, newPrefix string) error {
	query := `
		UPDATE oss_prefix_config
		SET old_prefix_domain = $1, new_prefix_domain = $2, updated_at = CURRENT_TIMESTAMP
		WHERE id = $3
	`

	_, err := r.DB.Exec(query, oldPrefix, newPrefix, id)
	return err
}
