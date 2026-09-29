// burn keeps the ANE busy with a MIL model directory for a fixed duration.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/tmc/apple/x/ane"
)

func main() {
	dur := flag.Duration("t", 15*time.Second, "run time")
	duty := flag.Float64("duty", 1, "fraction of each period spent submitting work")
	period := flag.Duration("period", 200*time.Millisecond, "duty-cycle period")
	flag.Parse()
	dir := flag.Arg(0)
	milText, err := os.ReadFile(filepath.Join(dir, "model.mil"))
	if err != nil {
		log.Fatal(err)
	}
	blob, err := os.ReadFile(filepath.Join(dir, "weights", "weight.bin"))
	if err != nil {
		log.Fatal(err)
	}
	c, err := ane.Open()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()
	m, err := c.Compile(ane.CompileOptions{ModelType: ane.ModelTypeMIL, MILText: milText, WeightBlob: blob})
	if err != nil {
		log.Fatal(err)
	}
	defer m.Close()
	start, n := time.Now(), 0
	var evalTime time.Duration
	on := time.Duration(float64(*period) * *duty)
	for time.Since(start) < *dur {
		ps := time.Now()
		for time.Since(ps) < on || *duty >= 1 {
			t0 := time.Now()
			if err := m.Eval(); err != nil {
				log.Fatal(err)
			}
			evalTime += time.Since(t0)
			n++
			if *duty >= 1 && time.Since(start) >= *dur {
				break
			}
		}
		if rest := *period - time.Since(ps); rest > 0 && *duty < 1 {
			time.Sleep(rest)
		}
	}
	el := time.Since(start)
	fmt.Printf("%s evals=%d  %.3f ms/eval  host-busy=%.1f%%\n", filepath.Base(dir), n, float64(el.Microseconds())/1000/float64(n), 100*evalTime.Seconds()/el.Seconds())
}
