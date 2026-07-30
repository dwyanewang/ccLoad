package main

import "testing"

func TestListenAddress(t *testing.T) {
	t.Setenv("CCLOAD_LISTEN_ADDR", "")
	if got, want := listenAddress("8808"), ":8808"; got != want {
		t.Fatalf("listenAddress() = %q, want %q", got, want)
	}

	t.Setenv("CCLOAD_LISTEN_ADDR", "127.0.0.1")
	if got, want := listenAddress(":8810"), "127.0.0.1:8810"; got != want {
		t.Fatalf("listenAddress() = %q, want %q", got, want)
	}

	t.Setenv("CCLOAD_LISTEN_ADDR", "::1")
	if got, want := listenAddress("8811"), "[::1]:8811"; got != want {
		t.Fatalf("listenAddress() = %q, want %q", got, want)
	}
}
