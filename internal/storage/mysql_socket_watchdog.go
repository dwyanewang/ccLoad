package storage

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
)

const defaultMySQLSocketSelfHealDelay = time.Minute

// MySQLSocketWatchdog restarts a container only when the Unix socket named by
// CCLOAD_MYSQL has disappeared continuously for its grace period. This covers
// a bind mount that remains attached to an obsolete runtime directory after
// the host MySQL service recreates that directory.
//
// It intentionally does not react to ordinary database failures: those may be
// transient connection, authentication, or query errors, none of which can be
// corrected by recreating the container.
type MySQLSocketWatchdog struct {
	socketPath   string
	gracePeriod  time.Duration
	pollInterval time.Duration
}

// NewMySQLSocketWatchdogFromEnv enables the watchdog only for containers that
// use a MySQL Unix-socket DSN. CCLOAD_MYSQL_SOCKET_SELF_HEAL_SECONDS defaults
// to 60; set it to 0 to disable the watchdog.
func NewMySQLSocketWatchdogFromEnv() (*MySQLSocketWatchdog, error) {
	if !isContainerRuntime() {
		return nil, nil
	}

	socketPath, ok, err := mysqlUnixSocketPath(strings.TrimSpace(os.Getenv("CCLOAD_MYSQL")))
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}

	gracePeriod, err := mysqlSocketSelfHealDelay(strings.TrimSpace(os.Getenv("CCLOAD_MYSQL_SOCKET_SELF_HEAL_SECONDS")))
	if err != nil {
		return nil, err
	}
	if gracePeriod == 0 {
		log.Printf("[INFO] MySQL Unix Socket 自愈监控已禁用")
		return nil, nil
	}

	return &MySQLSocketWatchdog{
		socketPath:   socketPath,
		gracePeriod:  gracePeriod,
		pollInterval: mysqlSocketWatchdogPollInterval(gracePeriod),
	}, nil
}

func isContainerRuntime() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CCLOAD_CONTAINER"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func mysqlUnixSocketPath(dsn string) (string, bool, error) {
	if dsn == "" {
		return "", false, nil
	}

	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return "", false, fmt.Errorf("解析 CCLOAD_MYSQL 失败: %w", err)
	}
	if cfg.Net != "unix" || cfg.Addr == "" {
		return "", false, nil
	}
	return cfg.Addr, true, nil
}

func mysqlSocketSelfHealDelay(value string) (time.Duration, error) {
	if value == "" {
		return defaultMySQLSocketSelfHealDelay, nil
	}

	seconds, err := strconv.Atoi(value)
	if err != nil || seconds < 0 {
		return 0, fmt.Errorf("CCLOAD_MYSQL_SOCKET_SELF_HEAL_SECONDS 必须是非负整数秒，实际为 %q", value)
	}
	return time.Duration(seconds) * time.Second, nil
}

func mysqlSocketWatchdogPollInterval(gracePeriod time.Duration) time.Duration {
	interval := min(5*time.Second, gracePeriod/4)
	return max(100*time.Millisecond, interval)
}

// Start runs the watchdog in the background. restart is invoked at most once,
// after the socket has been absent for the entire configured grace period.
func (w *MySQLSocketWatchdog) Start(ctx context.Context, restart func()) {
	go w.run(ctx, restart)
}

func (w *MySQLSocketWatchdog) run(ctx context.Context, restart func()) {
	ticker := time.NewTicker(w.pollInterval)
	defer ticker.Stop()

	var missing socketMissingTracker
	for {
		now := time.Now()
		missingNow := mysqlSocketMissing(w.socketPath)
		becameMissing, recovered, missingFor := missing.observe(now, missingNow)
		if becameMissing {
			log.Printf("[WARN] MySQL Unix Socket %s 不存在；若持续 %s，将退出容器以刷新 Socket 挂载", w.socketPath, w.gracePeriod)
		}
		if recovered {
			log.Printf("[INFO] MySQL Unix Socket %s 已恢复（缺失 %s）", w.socketPath, missingFor)
		}
		if missingNow && missingFor >= w.gracePeriod {
			log.Printf("[ERROR] MySQL Unix Socket %s 已持续缺失 %s，退出容器以刷新 Socket 挂载", w.socketPath, missingFor)
			restart()
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func mysqlSocketMissing(path string) bool {
	_, err := os.Stat(path)
	return errors.Is(err, fs.ErrNotExist)
}

type socketMissingTracker struct {
	missingSince time.Time
}

// observe reports state changes and the elapsed missing period. A stat error
// other than ENOENT is treated as present so permission failures cannot cause
// a restart loop.
func (t *socketMissingTracker) observe(now time.Time, isMissing bool) (becameMissing, recovered bool, missingFor time.Duration) {
	if !isMissing {
		if t.missingSince.IsZero() {
			return false, false, 0
		}
		missingFor = now.Sub(t.missingSince)
		t.missingSince = time.Time{}
		return false, true, missingFor
	}

	if t.missingSince.IsZero() {
		t.missingSince = now
		return true, false, 0
	}
	return false, false, now.Sub(t.missingSince)
}
