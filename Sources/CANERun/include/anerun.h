#ifndef ANERUN_H
#define ANERUN_H

// Runs a MIL model directory (model.mil + weights/weight.bin) on the ANE
// through the private AppleNeuralEngine framework (_ANEClient → aned).

typedef struct anerun anerun;

// Compiles and loads the model. On failure returns NULL and writes a message
// to err.
anerun *anerun_open(const char *model_dir, char *err, int errlen);

// Runs one synchronous inference. Returns 0 on success.
int anerun_eval(anerun *r, char *err, int errlen);

void anerun_close(anerun *r);

#endif
