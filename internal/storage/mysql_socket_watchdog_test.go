package storage

import (
	"path/filepath"
	"testing"
	"time"
)

func TestMySQLUnixSocketPath(t *testing.T) {
	tests := []struct {
		name     string
		dsn      string
		wantPath string
		wantOK   bool
		wantErr  bool
	}{
		{
			name:     "unix socket",
			dsn:      "ccload:secret@unix(/var/run/mysqld/mysqld.sock)/ccload?parseTime=true",
			wantPath: "/var/run/mysqld/mysqld.sock",
			wantOK:   true,
		},
		{
			name:   "tcp",
			dsn:    "ccload:secret@tcp(127.0.0.1:3306)/ccload?parseTime=true",
			wantOK: false,
		},
		{
			name:    "invalid",
			dsn:     "not-a-dsn",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotPath, gotOK, err := mysqlUnixSocketPath(tt.dsn)
			if (err != nil) != tt.wantErr {
				t.Fatalf("mysqlUnixSocketPath() error = %v, wantErr %v", err, tt.wantErr)
			}
			if gotPath != tt.wantPath || gotOK != tt.wantOK {
				t.Fatalf("mysqlUnixSocketPath() = (%q, %v), want (%q, %v)", gotPath, gotOK, tt.wantPath, tt.wantOK)
			}
		})
	}
}

func TestMySQLSocketSelfHealDelay(t *testing.T) {
	tests := []struct {
		value   string
		want    time.Duration
		wantErr bool
	}{
		{value: "", want: time.Minute},
		{value: "0", want: 0},
		{value: "75", want: 75 * time.Second},
		{value: "-1", wantErr: true},
		{value: "one-minute", wantErr: true},
	}

	for _, tt := range tests {
		got, err := mysqlSocketSelfHealDelay(tt.value)
		if (err != nil) != tt.wantErr {
			t.Fatalf("mysqlSocketSelfHealDelay(%q) error = %v, wantErr %v", tt.value, err, tt.wantErr)
		}
		if got != tt.want {
			t.Fatalf("mysqlSocketSelfHealDelay(%q) = %s, want %s", tt.value, got, tt.want)
		}
	}
}

func TestNewMySQLSocketWatchdogFromEnv(t *testing.T) {
	t.Setenv("CCLOAD_CONTAINER", "1")
	t.Setenv("CCLOAD_MYSQL", "ccload:secret@unix(/var/run/mysqld/mysqld.sock)/ccload?parseTime=true")
	t.Setenv("CCLOAD_MYSQL_SOCKET_SELF_HEAL_SECONDS", "75")

	watchdog, err := NewMySQLSocketWatchdogFromEnv()
	if err != nil {
		t.Fatalf("NewMySQLSocketWatchdogFromEnv() error = %v", err)
	}
	if watchdog == nil {
		t.Fatal("NewMySQLSocketWatchdogFromEnv() = nil, want watchdog")
	}
	if watchdog.socketPath != "/var/run/mysqld/mysqld.sock" || watchdog.gracePeriod != 75*time.Second {
		t.Fatalf("watchdog = %+v, want socket path and 75s grace period", watchdog)
	}

	t.Setenv("CCLOAD_MYSQL_SOCKET_SELF_HEAL_SECONDS", "0")
	watchdog, err = NewMySQLSocketWatchdogFromEnv()
	if err != nil {
		t.Fatalf("disabled NewMySQLSocketWatchdogFromEnv() error = %v", err)
	}
	if watchdog != nil {
		t.Fatalf("disabled NewMySQLSocketWatchdogFromEnv() = %+v, want nil", watchdog)
	}
}

func TestSocketMissingTrackerOnlyTripsAfterContinuousMissing(t *testing.T) {
	start := time.Date(2026, time.September, 2, 6, 22, 0, 0, time.UTC)
	grace := time.Minute
	var tracker socketMissingTracker

	becameMissing, recovered, missingFor := tracker.observe(start, true)
	if !becameMissing || recovered || missingFor != 0 {
		t.Fatalf("first missing observation = (%v, %v, %s), want (true, false, 0)", becameMissing, recovered, missingFor)
	}

	_, _, missingFor = tracker.observe(start.Add(59*time.Second), true)
	if missingFor >= grace {
		t.Fatalf("missing duration %s reached grace period too early", missingFor)
	}

	_, recovered, missingFor = tracker.observe(start.Add(59*time.Second), false)
	if !recovered || missingFor != 59*time.Second {
		t.Fatalf("recovery observation = (%v, %s), want (true, 59s)", recovered, missingFor)
	}

	becameMissing, _, _ = tracker.observe(start.Add(2*time.Minute), true)
	if !becameMissing {
		t.Fatal("a later missing period should start from zero")
	}
	_, _, missingFor = tracker.observe(start.Add(3*time.Minute), true)
	if missingFor != grace {
		t.Fatalf("continuous missing duration = %s, want %s", missingFor, grace)
	}
}

func TestMySQLSocketMissing(t *testing.T) {
	if !mysqlSocketMissing(filepath.Join(t.TempDir(), "missing.sock")) {
		t.Fatal("missing socket path should be detected")
	}
	if mysqlSocketMissing(t.TempDir()) {
		t.Fatal("existing path should not be detected as missing")
	}
}
