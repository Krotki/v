fn test_hello() {
}

fn test_2_plus_2() {
	four := 2 + 2
	assert four == 4
}

fn test_failing() {
	four := 2 + 2
	assert four == 100
}

fn test_panic() {
	println('This is visible')
	panic('Some unknown error')
	// println("This is not visible")
}
