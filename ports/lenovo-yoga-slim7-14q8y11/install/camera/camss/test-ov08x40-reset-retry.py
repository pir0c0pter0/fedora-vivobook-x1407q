#!/usr/bin/env python3
"""Exercise the actual OV08X40 start function with per-stage I/O failures."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
start = source[source.index("static int ov08x40_start_streaming("):
               source.index("/* Stop streaming */")]
stubs = r"""
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#define OV08X40_REG_SOFTWARE_RST 0x0103
#define OV08X40_SOFTWARE_RST 1
#define OV08X40_REG_VALUE_08BIT 1
#define OV08X40_REG_MODE_SELECT 0x0100
#define OV08X40_MODE_STREAMING 1
#define OV08X40_REG_XTALK_FIRST_A 2
#define OV08X40_REG_XTALK_LAST_A 3
#define OV08X40_REG_XTALK_FIRST_B 4
#define OV08X40_REG_XTALK_LAST_B 5
#define dev_err(...) ((void)0)
struct ov08x40_reg_list { int stage; };
struct mode { int link_freq_index, exposure_shift; struct ov08x40_reg_list reg_list; };
struct ov08x40 { void *dev; struct mode *cur_mode; struct { void *ctrl_handler; } sd; };
static struct { struct ov08x40_reg_list reg_list; } link_freq_configs[] = {{{1}}};
static struct ov08x40_reg_list ov08x40_global_setting = {2};
static int reset_errors[2], reset_count, failure_stage, stage_error, seen[8];
static int ov08x40_write_reg(struct ov08x40 *s, unsigned reg, unsigned width, unsigned val) {
 assert(width == 1 && val == 1);
 if (reg == OV08X40_REG_SOFTWARE_RST) {
  assert(reset_count < 2); return reset_errors[reset_count++];
 }
 assert(reg == OV08X40_REG_MODE_SELECT); ++seen[7];
 return failure_stage == 7 ? stage_error : 0;
}
static int ov08x40_write_reg_list(struct ov08x40 *s, const struct ov08x40_reg_list *r)
{ ++seen[r->stage]; return failure_stage == r->stage ? stage_error : 0; }
static int ov08x40_burst_fill_regs(struct ov08x40 *s, unsigned first, unsigned last, unsigned value)
{ int stage = first == OV08X40_REG_XTALK_FIRST_A ? 4 : 5;
 ++seen[stage]; return failure_stage == stage ? stage_error : 0; }
static int __v4l2_ctrl_handler_setup(void *handler)
{ ++seen[6]; return failure_stage == 6 ? stage_error : 0; }
static void setup(int first, int second, int failed_stage, int error) {
 reset_errors[0] = first; reset_errors[1] = second; reset_count = 0;
 failure_stage = failed_stage; stage_error = error;
 for (int i = 0; i < 8; ++i) seen[i] = 0;
}
"""
main = r"""
int main(void) {
 struct mode mode = { .link_freq_index = 0, .exposure_shift = 1, .reg_list = {3} };
 struct ov08x40 sensor = { .cur_mode = &mode };
 setup(0, 0, 0, 0);
 assert(ov08x40_start_streaming(&sensor) == 0); assert(reset_count == 1);
 for (int i = 1; i < 8; ++i) assert(seen[i] == 1);
 setup(-ETIMEDOUT, 0, 0, 0);
 assert(ov08x40_start_streaming(&sensor) == 0); assert(reset_count == 2);
 for (int i = 1; i < 8; ++i) assert(seen[i] == 1);
 const int errors[] = {-ETIMEDOUT, -ENXIO, -EIO, -EINVAL};
 for (unsigned e = 0; e < 4; ++e) {
  setup(-ETIMEDOUT, errors[e], 0, 0);
  assert(ov08x40_start_streaming(&sensor) == errors[e]); assert(reset_count == 2);
  for (int i = 1; i < 8; ++i) assert(seen[i] == 0);
 }
 for (unsigned e = 1; e < 4; ++e) {
  setup(errors[e], 0, 0, 0);
  assert(ov08x40_start_streaming(&sensor) == errors[e]); assert(reset_count == 1);
  for (int i = 1; i < 8; ++i) assert(seen[i] == 0);
 }
 for (int failure = 1; failure < 8; ++failure) {
  setup(0, 0, failure, -ETIMEDOUT);
  assert(ov08x40_start_streaming(&sensor) == -ETIMEDOUT); assert(reset_count == 1);
  for (int i = 1; i < 8; ++i) assert(seen[i] == (i <= failure));
 }
 mode.exposure_shift = 0;
 for (int retry = 0; retry < 2; ++retry) {
  setup(retry ? -ETIMEDOUT : 0, 0, 0, 0);
  assert(ov08x40_start_streaming(&sensor) == 0); assert(reset_count == 1 + retry);
  for (int i = 1; i < 8; ++i) assert(seen[i] == (i != 4 && i != 5));
 }
 puts("PASS: 18 cases; bounded initial retry, later stages unretried, full/binned modes");
}
"""
with tempfile.TemporaryDirectory(prefix="ov08x40-retry-") as directory:
    test = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    test.write_text(stubs + start + main)
    subprocess.run(["cc", "-std=gnu11", "-O0", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
