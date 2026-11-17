#!/usr/bin/env python3
"""Exercise real CCI probe initialization/reset with each enabled-bus mask.

Usage: test-cci-completion.py path/to/i2c-qcom-cci.c
The completion stub checks the wait-list invariant which zeroed memory lacks.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
probe_start = source.index("static int cci_probe(")
probe_end = source.index("\n\t/* Memory */", probe_start)
probe = source[probe_start:probe_end] + "\n return 0;\n}\n"
reset_start = source.index("static int cci_reset(")
reset_end = source.index("\nstatic int cci_run_queue(", reset_start)
reset = source[reset_start:reset_end]

stubs = r"""
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define GFP_KERNEL 0
#define I2C_MODE_STANDARD 0
#define I2C_MODE_FAST 1
#define I2C_MODE_FAST_PLUS 2
#define I2C_MAX_FAST_MODE_FREQ 400000
#define I2C_MAX_FAST_MODE_PLUS_FREQ 1000000
#define CCI_RESET_CMD 0
#define CCI_RESET_CMD_MASK 1
#define CCI_TIMEOUT 1
#define dev_err(...) ((void)0)
struct completion { struct completion *wait_next; unsigned done; };
struct device_node { unsigned index; };
struct device { struct device *parent; struct device_node *of_node; };
struct platform_device { struct device dev; };
struct resource { int unused; };
struct cci_data { unsigned num_masters; int quirks; };
struct cci;
struct cci_master {
 struct { const int *quirks, *algo; struct device dev; char name[32]; } adap;
 unsigned master, mode; struct cci *cci; struct completion irq_complete;
};
struct cci { struct device *dev; const struct cci_data *data;
 struct cci_master master[2]; void *base; unsigned irq; };
static struct cci *active;
static const struct cci_data match = { .num_masters = 2 };
static struct device_node children[] = {{0}, {1}};
static unsigned enabled_mask;
static int cci_algo;
#define for_each_available_child_of_node_scoped(node, child) \
 for (struct device_node *child = children; child < children + 2; ++child) \
 if (enabled_mask & (1U << child->index))
#define devm_kzalloc(dev, size, flags) calloc(1, size)
#define platform_set_drvdata(dev, data) (active = (data))
#define device_get_match_data(dev) (&match)
#define of_node_get(node) (node)
#define devm_add_action_or_reset(dev, action, data) 0
#define i2c_set_adapdata(adap, data) ((void)0)
static int of_property_read_u32(struct device_node *node, const char *name, u32 *val)
{ *val = !strcmp(name, "reg") ? node->index : 400000; return 0; }
static void init_completion(struct completion *c) { c->wait_next = c; c->done = 0; }
static void reinit_completion(struct completion *c) { c->done = 0; }
static void complete(struct completion *c) { assert(c->wait_next == c); ++c->done; }
static int wait_for_completion_timeout(struct completion *c, unsigned timeout)
{ assert(c->wait_next == c); return !!c->done; }
static void writel(unsigned val, void *address)
{ complete(&active->master[0].irq_complete); }
static int cci_init(struct cci *cci) { return 0; }
static void synchronize_irq(unsigned irq) { }
"""
main = r"""
int main(void) {
 struct platform_device pdev = {0};
 const unsigned masks[] = {2, 1, 3, 0};
 for (unsigned scenario = 0; scenario < 4; ++scenario) {
  enabled_mask = masks[scenario];
  fprintf(stderr, "enabled buses mask=%u\n", enabled_mask);
  assert(cci_probe(&pdev) == 0);
  assert(cci_reset(active) == 0);
  for (unsigned i = 0; i < 2; ++i) {
   assert(!!active->master[i].cci == !!(enabled_mask & (1U << i)));
   if (enabled_mask & (1U << i)) complete(&active->master[i].irq_complete);
  }
  free(active);
 }
 return 0;
}
"""
with tempfile.TemporaryDirectory(prefix="cci-completion-") as directory:
    test = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    test.write_text(stubs + probe + reset + main)
    subprocess.run(["cc", "-std=gnu11", "-O0", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
