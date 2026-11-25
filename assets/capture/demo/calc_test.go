package calc

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2, 3) = %d, want 5", got)
	}
}

func TestFib(t *testing.T) {
	if got := Fib(20); got != 6765 {
		t.Fatalf("Fib(20) = %d, want 6765", got)
	}
}

func BenchmarkFib20(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Fib(20)
	}
}

func BenchmarkFib25(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Fib(25)
	}
}
