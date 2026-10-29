// The program the privileged job builds and then runs, so the build produces something
// that reports where it ran rather than only succeeding.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	host, _ := os.Hostname()
	fmt.Printf("hello from a GitLab CI docker build inside a Nitro sandbox (%s/%s, container %s)\n",
		runtime.GOOS, runtime.GOARCH, host)
}
