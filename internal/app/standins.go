package app

// What setup runs that a test build stands in for, so that setup's tests
// neither bootstrap nor capture the machine running them.
var (
	captureMac        = (*Session).capture
	bootstrapCheckout = (*Session).Bootstrap
)
