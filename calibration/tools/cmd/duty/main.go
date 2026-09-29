// duty runs a 64x64 1x1 conv on the ANE with a fixed on/off duty cycle.
package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/tmc/apple/x/ane"
	"github.com/tmc/apple/x/ane/mil"
)

func main() {
	duty := flag.Float64("duty", 1, "fraction of each period spent evaluating")
	period := flag.Duration("period", 10*time.Millisecond, "on/off period")
	total := flag.Duration("t", 5*time.Second, "run time")
	flag.Parse()

	c, err := ane.Open()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()
	blob, err := mil.BuildIdentityWeightBlob(64)
	if err != nil {
		log.Fatal(err)
	}
	m, err := c.Compile(ane.CompileOptions{ModelType: ane.ModelTypeMIL, MILText: []byte(mil.GenConv(64, 64, 1)), WeightBlob: blob})
	if err != nil {
		log.Fatal(err)
	}
	defer m.Close()

	on := time.Duration(float64(*period) * *duty)
	end := time.Now().Add(*total)
	n := 0
	for time.Now().Before(end) {
		ps := time.Now()
		for time.Since(ps) < on {
			if err := m.Eval(); err != nil {
				log.Fatal(err)
			}
			n++
		}
		if rest := *period - time.Since(ps); rest > 0 {
			time.Sleep(rest)
		}
	}
	fmt.Printf("duty=%.2f evals=%d (%.0f/s)\n", *duty, n, float64(n)/total.Seconds())
}
