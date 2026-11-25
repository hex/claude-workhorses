// Package calc is the small module the README captures test on a workhorse.
package calc

// Add returns a + b.
func Add(a, b int) int { return a + b }

// Sub returns a - b.
func Sub(a, b int) int { return a - b }

// Fib returns the nth Fibonacci number, the slow way.
func Fib(n int) int {
	if n < 2 {
		return n
	}
	return Fib(n-1) + Fib(n-2)
}
