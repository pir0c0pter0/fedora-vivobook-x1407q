#!/usr/bin/env python3
"""Run the actual CCI runtime-resume/reset functions with fault-injected stubs.

Usage: test-cci-runtime.py path/to/i2c-qcom-cci.c
No hardware: tests clock errors, reset timeout, init errors and repeated resumes.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
reset = source[source.index("static int cci_reset("):
               source.index("\nstatic int cci_run_queue(")]
resume = source[source.index("static int __maybe_unused cci_resume_runtime("):
                source.index("\nstatic const struct dev_pm_ops qcom_cci_pm")]

stubs = r"""
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#define __maybe_unused
#define CCI_RESET_CMD 0
#define CCI_RESET_CMD_MASK 1
#define CCI_TIMEOUT 1
#define dev_err(...) ((void)0)
struct completion { int done; };
struct device { int unused; };
struct cci { struct device *dev; void *base; unsigned irq;
 struct { struct completion irq_complete; } master[2]; };
static struct cci instance;
static int clock_result, init_result, reset_ack;
static int enables, disables, resets, inits, syncs, pending_master1_ack;
static struct cci *dev_get_drvdata(struct device *dev) { return &instance; }
static int cci_enable_clocks(struct cci *cci) { ++enables; return clock_result; }
static void cci_disable_clocks(struct cci *cci) { ++disables; }
static void reinit_completion(struct completion *c) { c->done = 0; }
static void writel(unsigned val, void *address) {
 assert(enables > disables); assert(val == CCI_RESET_CMD_MASK);
 ++resets; instance.master[0].irq_complete.done = reset_ack;
 pending_master1_ack = reset_ack;
}
static int wait_for_completion_timeout(struct completion *c, unsigned timeout)
{ return c->done; }
static void synchronize_irq(unsigned irq) { ++syncs; pending_master1_ack = 0; }
static int cci_init(struct cci *cci)
{ assert(!pending_master1_ack); ++inits; return init_result; }
static void setup(int clock_error, int ack, int init_error) {
 clock_result = clock_error; reset_ack = ack; init_result = init_error;
 enables = disables = resets = inits = syncs = pending_master1_ack = 0;
}
"""
main = r"""
int main(void) {
 struct device dev = {0}; instance.dev = &dev;
 setup(0, 1, 0);
 assert(cci_resume_runtime(&dev) == 0);
 assert(enables == 1 && resets == 1 && inits == 1 && disables == 0);
 assert(syncs == 1);
 cci_disable_clocks(&instance);
 assert(cci_resume_runtime(&dev) == 0);
 assert(enables == 2 && resets == 2 && inits == 2 && disables == 1);
 assert(syncs == 2);
 setup(-EIO, 1, 0);
 assert(cci_resume_runtime(&dev) == -EIO);
 assert(enables == 1 && resets == 0 && inits == 0 && disables == 0);
 assert(syncs == 0);
 setup(0, 0, 0);
 assert(cci_resume_runtime(&dev) == -ETIMEDOUT);
 assert(enables == 1 && resets == 1 && inits == 0 && disables == 1);
 assert(syncs == 0);
 setup(0, 1, -EOPNOTSUPP);
 assert(cci_resume_runtime(&dev) == -EOPNOTSUPP);
 assert(enables == 1 && resets == 1 && inits == 1 && disables == 1);
 assert(syncs == 1);
 puts("PASS: success, repeated resume, clock failure, reset timeout, init failure");
}
"""
with tempfile.TemporaryDirectory(prefix="cci-runtime-") as directory:
    test = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    test.write_text(stubs + reset + resume + main)
    subprocess.run(["cc", "-std=gnu11", "-O0", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
