// sqlite-to-mysql copies a stopped ccLoad SQLite database into a fresh MySQL
// primary database. It deliberately does not try to be a live replication
// mechanism: the final invocation must happen after the SQLite writer has
// stopped, so every table is copied from one consistent source.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"ccLoad/internal/storage"
)

// schemaMigrations belongs to the target binary, not the copied data. The
// current binary creates and migrates MySQL before this tool touches rows, so
// retaining its migration journal makes later upgrades safe.
var applicationTables = []string{
	"channels",
	"api_keys",
	"channel_models",
	"channel_model_cooldowns",
	"channel_protocol_transforms",
	"channel_url_states",
	"auth_tokens",
	"system_settings",
	"web_sessions",
	"logs",
	"debug_logs",
	"model_fingerprints",
	"fingerprint_test_results",
}

type tablePlan struct {
	name       string
	columns    []string
	sourceRows int64
}

func main() {
	var sourcePath string
	var backupPath string
	var replace bool
	var dryRun bool

	flag.StringVar(&sourcePath, "sqlite", "", "path to the source ccLoad SQLite database")
	flag.StringVar(&backupPath, "backup", "", "optional new SQLite backup path; created before import")
	flag.BoolVar(&replace, "replace", false, "delete ccLoad rows already present in the MySQL target")
	flag.BoolVar(&dryRun, "dry-run", false, "validate source and target schemas without changing MySQL")
	flag.Parse()

	if strings.TrimSpace(sourcePath) == "" || flag.NArg() != 0 {
		fail("usage: sqlite-to-mysql --sqlite /path/ccload.db [--backup /path/backup.db] --replace [--dry-run]")
	}
	if !dryRun && !replace {
		fail("refusing to modify MySQL without --replace")
	}
	if err := validateStorageEnvironment(); err != nil {
		fail(err.Error())
	}

	if _, err := os.Stat(sourcePath); err != nil {
		fail(fmt.Sprintf("source SQLite database is unavailable: %v", err))
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if backupPath != "" {
		if err := createSQLiteBackup(ctx, sourcePath, backupPath); err != nil {
			fail(fmt.Sprintf("create SQLite backup: %v", err))
		}
		sourcePath = backupPath
	}

	if err := ensureMySQLSchema(); err != nil {
		fail(fmt.Sprintf("initialize MySQL schema: %v", err))
	}

	source, err := openSQLite(sourcePath)
	if err != nil {
		fail(fmt.Sprintf("open source SQLite: %v", err))
	}
	defer func() { _ = source.Close() }()

	target, err := sql.Open("mysql", os.Getenv("CCLOAD_MYSQL"))
	if err != nil {
		fail(fmt.Sprintf("open MySQL target: %v", err))
	}
	defer func() { _ = target.Close() }()
	if err := target.PingContext(ctx); err != nil {
		fail(fmt.Sprintf("ping MySQL target: %v", err))
	}

	plans, err := buildPlans(ctx, source, target)
	if err != nil {
		fail(fmt.Sprintf("validate databases: %v", err))
	}
	for _, plan := range plans {
		log.Printf("[PLAN] %s: %d rows, %d copied columns", plan.name, plan.sourceRows, len(plan.columns))
	}
	if dryRun {
		log.Print("[OK] dry run passed; MySQL was not changed")
		return
	}

	if err := copyAll(ctx, source, target, plans); err != nil {
		fail(fmt.Sprintf("copy SQLite data to MySQL: %v", err))
	}

	log.Print("[OK] SQLite to MySQL migration completed and row counts match")
}

func validateStorageEnvironment() error {
	if strings.TrimSpace(os.Getenv("CCLOAD_MYSQL")) == "" {
		return errors.New("CCLOAD_MYSQL must contain the target MySQL DSN")
	}
	if strings.TrimSpace(os.Getenv("CCLOAD_POSTGRES")) != "" {
		return errors.New("CCLOAD_POSTGRES must be unset during a MySQL migration")
	}
	if strings.TrimSpace(os.Getenv("CCLOAD_ENABLE_SQLITE_REPLICA")) == "1" {
		return errors.New("CCLOAD_ENABLE_SQLITE_REPLICA must be disabled; this migration targets pure MySQL")
	}
	return nil
}

func ensureMySQLSchema() error {
	store, err := storage.NewStore()
	if err != nil {
		return err
	}
	return store.Close()
}

func openSQLite(path string) (*sql.DB, error) {
	fileURL := (&url.URL{Scheme: "file", Path: path}).String()
	db, err := sql.Open("sqlite", fileURL+"?_pragma=busy_timeout(5000)&_foreign_keys=on")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	return db, nil
}

// createSQLiteBackup uses SQLite's online backup command rather than copying
// only the .db file. The latter can lose uncheckpointed WAL records.
func createSQLiteBackup(ctx context.Context, sourcePath, backupPath string) error {
	if filepath.Clean(sourcePath) == filepath.Clean(backupPath) {
		return errors.New("backup path must differ from the source path")
	}
	if _, err := os.Stat(backupPath); err == nil {
		return fmt.Errorf("backup destination already exists: %s", backupPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(backupPath), 0o750); err != nil {
		return err
	}

	db, err := openSQLite(sourcePath)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	_, err = db.ExecContext(ctx, "VACUUM INTO "+sqliteStringLiteral(backupPath))
	return err
}

func buildPlans(ctx context.Context, source, target *sql.DB) ([]tablePlan, error) {
	plans := make([]tablePlan, 0, len(applicationTables))
	for _, table := range applicationTables {
		exists, err := sqliteTableExists(ctx, source, table)
		if err != nil {
			return nil, fmt.Errorf("check source table %s: %w", table, err)
		}
		if !exists {
			log.Printf("[WARN] source table %s does not exist; target remains empty", table)
			continue
		}

		sourceColumns, err := tableColumns(ctx, source, quoteSQLiteIdentifier(table))
		if err != nil {
			return nil, fmt.Errorf("read source columns for %s: %w", table, err)
		}
		targetColumns, err := tableColumns(ctx, target, quoteMySQLIdentifier(table))
		if err != nil {
			return nil, fmt.Errorf("read target columns for %s: %w", table, err)
		}

		commonColumns := make([]string, 0, len(sourceColumns))
		for _, column := range sourceColumns {
			if slices.Contains(targetColumns, column) {
				commonColumns = append(commonColumns, column)
			}
		}
		if len(commonColumns) == 0 {
			return nil, fmt.Errorf("table %s has no common source/target columns", table)
		}
		if err := ensureRequiredTargetColumnsPresent(ctx, target, table, commonColumns); err != nil {
			return nil, err
		}

		rows, err := tableCount(ctx, source, quoteSQLiteIdentifier(table))
		if err != nil {
			return nil, fmt.Errorf("count source rows for %s: %w", table, err)
		}
		plans = append(plans, tablePlan{name: table, columns: commonColumns, sourceRows: rows})
	}
	return plans, nil
}

func sqliteTableExists(ctx context.Context, db *sql.DB, table string) (bool, error) {
	var one int
	err := db.QueryRowContext(ctx, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", table).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func tableColumns(ctx context.Context, db *sql.DB, table string) ([]string, error) {
	rows, err := db.QueryContext(ctx, "SELECT * FROM "+table+" LIMIT 0")
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	return rows.Columns()
}

func ensureRequiredTargetColumnsPresent(ctx context.Context, target *sql.DB, table string, sourceColumns []string) error {
	rows, err := target.QueryContext(ctx, `
SELECT column_name, is_nullable, column_default, extra
FROM information_schema.columns
WHERE table_schema = DATABASE() AND table_name = ?`, table)
	if err != nil {
		return fmt.Errorf("inspect MySQL columns for %s: %w", table, err)
	}
	defer func() { _ = rows.Close() }()

	for rows.Next() {
		var name, nullable, extra string
		var defaultValue sql.NullString
		if err := rows.Scan(&name, &nullable, &defaultValue, &extra); err != nil {
			return err
		}
		if slices.Contains(sourceColumns, name) || nullable == "YES" || defaultValue.Valid || strings.Contains(strings.ToLower(extra), "auto_increment") {
			continue
		}
		return fmt.Errorf("target table %s has required column %s that is absent from SQLite", table, name)
	}
	return rows.Err()
}

func copyAll(ctx context.Context, source, target *sql.DB, plans []tablePlan) error {
	conn, err := target.Conn(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	if _, err := conn.ExecContext(ctx, "SET FOREIGN_KEY_CHECKS = 0"); err != nil {
		return err
	}
	defer func() { _, _ = conn.ExecContext(context.Background(), "SET FOREIGN_KEY_CHECKS = 1") }()
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	for i := len(plans) - 1; i >= 0; i-- {
		if _, err := tx.ExecContext(ctx, "DELETE FROM "+quoteMySQLIdentifier(plans[i].name)); err != nil {
			return fmt.Errorf("clear target table %s: %w", plans[i].name, err)
		}
	}

	for _, plan := range plans {
		if err := copyTable(ctx, tx, source, plan); err != nil {
			return err
		}
	}
	if err := verifyCounts(ctx, source, tx, plans); err != nil {
		return err
	}
	return tx.Commit()
}

func copyTable(ctx context.Context, target *sql.Tx, source *sql.DB, plan tablePlan) error {
	if plan.sourceRows == 0 {
		log.Printf("[COPY] %s: 0 rows", plan.name)
		return nil
	}

	columns := make([]string, len(plan.columns))
	for i, column := range plan.columns {
		columns[i] = quoteMySQLIdentifier(column)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(columns)), ",")
	insertSQL := "INSERT INTO " + quoteMySQLIdentifier(plan.name) + " (" + strings.Join(columns, ", ") + ") VALUES (" + placeholders + ")"

	stmt, err := target.PrepareContext(ctx, insertSQL)
	if err != nil {
		return fmt.Errorf("prepare insert for %s: %w", plan.name, err)
	}
	defer func() { _ = stmt.Close() }()

	rows, err := source.QueryContext(ctx, "SELECT "+strings.Join(quoteSQLiteColumns(plan.columns), ", ")+" FROM "+quoteSQLiteIdentifier(plan.name))
	if err != nil {
		return fmt.Errorf("read source table %s: %w", plan.name, err)
	}
	defer func() { _ = rows.Close() }()

	values := make([]any, len(plan.columns))
	scanTargets := make([]any, len(plan.columns))
	for i := range values {
		scanTargets[i] = &values[i]
	}

	var copied int64
	for rows.Next() {
		if err := rows.Scan(scanTargets...); err != nil {
			return fmt.Errorf("scan source row from %s: %w", plan.name, err)
		}
		if _, err := stmt.ExecContext(ctx, values...); err != nil {
			return fmt.Errorf("insert row into %s: %w", plan.name, err)
		}
		copied++
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate source table %s: %w", plan.name, err)
	}
	log.Printf("[COPY] %s: %d rows", plan.name, copied)
	return nil
}

type rowCounter interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func verifyCounts(ctx context.Context, source, target rowCounter, plans []tablePlan) error {
	for _, plan := range plans {
		sourceRows, err := tableCount(ctx, source, quoteSQLiteIdentifier(plan.name))
		if err != nil {
			return err
		}
		targetRows, err := tableCount(ctx, target, quoteMySQLIdentifier(plan.name))
		if err != nil {
			return err
		}
		if sourceRows != targetRows {
			return fmt.Errorf("table %s count mismatch: source=%d target=%d", plan.name, sourceRows, targetRows)
		}
		log.Printf("[VERIFY] %s: %d rows", plan.name, targetRows)
	}
	return nil
}

func tableCount(ctx context.Context, db rowCounter, table string) (int64, error) {
	var count int64
	err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+table).Scan(&count)
	return count, err
}

func quoteSQLiteColumns(columns []string) []string {
	quoted := make([]string, len(columns))
	for i, column := range columns {
		quoted[i] = quoteSQLiteIdentifier(column)
	}
	return quoted
}

func quoteSQLiteIdentifier(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `""`) + `"`
}

func quoteMySQLIdentifier(value string) string {
	return "`" + strings.ReplaceAll(value, "`", "``") + "`"
}

func sqliteStringLiteral(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func fail(message string) {
	log.Print("[FATAL] " + message)
	os.Exit(1)
}
