package utils

import (
	"time"
)

// 上海时区
var ShanghaiLocation *time.Location

func init() {
	var err error
	ShanghaiLocation, err = time.LoadLocation("Asia/Shanghai")
	if err != nil {
		// 如果无法加载时区，使用固定偏移量 UTC+8
		ShanghaiLocation = time.FixedZone("CST", 8*60*60)
	}
}

// NowInShanghai 获取当前上海时区时间
func NowInShanghai() time.Time {
	return time.Now().In(ShanghaiLocation)
}

// ToShanghaiTime 将任意时间转换为上海时区时间
func ToShanghaiTime(t time.Time) time.Time {
	return t.In(ShanghaiLocation)
}

// UTCToShanghai 将 UTC 时间转换为上海时区时间
func UTCToShanghai(utcTime time.Time) time.Time {
	return utcTime.In(ShanghaiLocation)
}

// ShanghaiToUTC 将上海时区时间转换为 UTC 时间
func ShanghaiToUTC(shanghaiTime time.Time) time.Time {
	return shanghaiTime.UTC()
}

// ParseToShanghaiTime 解析时间字符串并转换为上海时区时间
// 支持多种格式：RFC3339、ISO8601 等
func ParseToShanghaiTime(timeStr string) (time.Time, error) {
	// 尝试多种格式解析
	formats := []string{
		time.RFC3339,
		time.RFC3339Nano,
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05",
		"2006-01-02",
	}

	var parsedTime time.Time
	var err error

	for _, format := range formats {
		parsedTime, err = time.Parse(format, timeStr)
		if err == nil {
			break
		}
	}

	if err != nil {
		return time.Time{}, err
	}

	// 转换为上海时区
	return ToShanghaiTime(parsedTime), nil
}

// FormatShanghaiTime 将时间格式化为上海时区的 ISO8601 字符串
func FormatShanghaiTime(t time.Time) string {
	shanghaiTime := ToShanghaiTime(t)
	return shanghaiTime.Format("2006-01-02T15:04:05")
}

// FormatShanghaiTimeRFC3339 将时间格式化为上海时区的 RFC3339 字符串
func FormatShanghaiTimeRFC3339(t time.Time) string {
	shanghaiTime := ToShanghaiTime(t)
	return shanghaiTime.Format(time.RFC3339)
}
