//go:build !darwin

package main

// renderSymbol has no SF Symbols to draw outside macOS.
func renderSymbol(string, float64) []byte { return nil }
