#!/usr/bin/env python3
"""Exercise actual private test functions with a fault-injecting register model."""
from pathlib import Path
import subprocess
import tempfile
import sys

source = Path(sys.argv[1]).read_text()
def function(name):
    start = source.index('static int ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define BIT(n) (1u << (n))
#define FIELD_PREP(mask,v) ((v) << __builtin_ctz(mask))
#define FLASH_STROBE_HW_SW_SEL_BIT BIT(2)
#define FLASH_HW_STROBE_TRIGGER_SEL_BIT BIT(1)
#define FLASH_STROBE_POLARITY_BIT BIT(0)
#define SW_STROBE_VAL 0
#define HW_STROBE_VAL 1
#define STROBE_LEVEL_TRIGGER_VAL 0
#define STROBE_ACTIVE_HIGH_VAL 1
#define FLASH_MODE 1
#define REG_CHAN_EN 0
#define REG_CHAN_STROBE 1
#define REG_MODULE_EN 2
#define EE67 3
#define dev_info(...) ((void)0)
enum led_strobe { SW_STROBE, HW_STROBE };
static bool diagnostic_windows_ee67=true;
struct qcom_flash_data {
 int r_fields[3], diagnostic_ee67;
 u32 diagnostic_saved; bool diagnostic_saved_valid;
};
struct qcom_flash_led {
 struct qcom_flash_data *flash_data;
 u8 chan_id[2]; int chan_count; bool enabled;
 u32 flash_timeout_ms, flash_current_ma;
};
struct led_classdev_flash { struct qcom_flash_led *led; };
struct v4l2_flash { struct led_classdev_flash *fled_cdev; };
static int event, fail_at, module_on, channels, current_done, timer_done, enable_seen;
static int fail_writes_apply, ee67, ee67_writes, bad_gate_read, bad_ee67_read;
static int trip(void) { return ++event==fail_at ? -EIO : 0; }
static int regmap_field_update_bits(int field, int mask, int value) {
 assert(field==REG_CHAN_EN); int rc=trip(); if(rc && !fail_writes_apply) return rc;
 if(value) { assert(current_done && timer_done && module_on); enable_seen=1; }
 channels=(channels & ~mask)|value; return rc;
}
static int regmap_fields_write(int field, int channel, int value) {
 assert(field==REG_CHAN_STROBE); assert(channel==0 || channel==3);
 assert(!channels); /* A source change is forbidden until channels are OFF. */
 assert(value==5 || value==1); return trip();
}
static int regmap_field_read(int field,u32 *value) {
 int rc=trip(); if(rc) return rc;
 if(field==REG_CHAN_EN) *value=bad_gate_read ? 1 : channels;
 else if(field==REG_MODULE_EN) *value=module_on;
 else { assert(field==EE67); *value=(ee67 & 1) ^ bad_ee67_read; }
 return 0;
}
static int regmap_field_write(int field,u32 value) {
 assert(field==EE67 && value<=1);
 assert(!channels && !module_on); /* Includes every restore and fault path. */
 int rc=trip(); if(rc && !fail_writes_apply) return rc;
 ee67=(ee67 & ~1)|value; ee67_writes++; return rc;
}
static struct qcom_flash_led *flcdev_to_qcom_fled(struct led_classdev_flash *f) {return f->led;}
static int set_flash_module_en(struct qcom_flash_led *l,bool en) {
 (void)l; int rc=trip(); if(rc && !fail_writes_apply) return rc;
 if(en) {
  assert(current_done && timer_done && !channels);
  if(diagnostic_windows_ee67) assert(!(ee67 & 1));
 }
 module_on=en; return rc;
}
static int update_allowed_flash_current(struct qcom_flash_led *l,u32 *m,bool en) {
 (void)l; (void)m; assert(en && !channels && !module_on); return trip();
}
static int set_flash_current(struct qcom_flash_led *l,u32 m,int mode) {
 (void)l; (void)m; assert(mode==FLASH_MODE && !channels && !module_on);
 int rc=trip(); if(!rc) current_done=1; return rc;
}
static int set_flash_timeout(struct qcom_flash_led *l,u32 ms) {
 (void)l; (void)ms; assert(!channels && !module_on);
 int rc=trip(); if(!rc) timer_done=1; return rc;
}
'''
for name in ('set_flash_strobe', 'diagnostic_windows_config',
             'diagnostic_external_off', 'qcom_flash_external_strobe_set'):
    harness += '\n' + function(name)
harness += r'''
static void reset(struct qcom_flash_data *d,int value,int failure,int ambiguous) {
 event=0; fail_at=failure; fail_writes_apply=ambiguous;
 module_on=channels=current_done=timer_done=enable_seen=0;
 ee67=value; ee67_writes=bad_gate_read=bad_ee67_read=0;
 d->diagnostic_saved_valid=false;
}
int main(void) {
 struct qcom_flash_data data={.r_fields={0,1,2},.diagnostic_ee67=EE67};
 struct qcom_flash_led led={.flash_data=&data,.chan_id={0,3},.chan_count=2,
  .flash_timeout_ms=10,.flash_current_ma=50};
 struct led_classdev_flash f={.led=&led}; struct v4l2_flash v={.fled_cdev=&f};
 for(int original=0;original<2;original++) {
  reset(&data,0xa4|original,0,0);
  assert(!qcom_flash_external_strobe_set(&v,true));
  assert(module_on && channels==9 && led.enabled && enable_seen);
  assert(ee67==0xa4 && data.diagnostic_saved_valid);
  int prepare_events=event;
  event=0; assert(!qcom_flash_external_strobe_set(&v,false));
  assert(!module_on && !channels && ee67==(0xa4|original));
  assert(!data.diagnostic_saved_valid);
  int off_events=event;
  for(int ambiguous=0;ambiguous<2;ambiguous++) {
   for(int failure=1;failure<=prepare_events;failure++) {
    reset(&data,0xa4|original,failure,ambiguous);
    assert(qcom_flash_external_strobe_set(&v,true)==-EIO);
    assert(!module_on && !channels && ee67==(0xa4|original));
    assert(!data.diagnostic_saved_valid);
   }
   for(int failure=1;failure<=off_events;failure++) {
    reset(&data,0xa4|original,0,ambiguous);
    assert(!qcom_flash_external_strobe_set(&v,true));
    event=0; fail_at=failure;
    assert(qcom_flash_external_strobe_set(&v,false)==-EIO);
    assert(!module_on && !channels && ee67==(0xa4|original));
    assert(!data.diagnostic_saved_valid);
   }
  }
  printf("PASS: initial bit%d, %d arm + %d OFF failure positions, including ambiguous writes\n",
         original,prepare_events,off_events);
 }
 reset(&data,0xa5,0,0); assert(!qcom_flash_external_strobe_set(&v,true));
 bad_gate_read=1;
 assert(qcom_flash_external_strobe_set(&v,false)==-EBUSY);
 assert(ee67==0xa4 && data.diagnostic_saved_valid && !module_on && !channels);
 bad_gate_read=0;
 assert(!qcom_flash_external_strobe_set(&v,false));
 assert(ee67==0xa5 && !data.diagnostic_saved_valid);
 reset(&data,0xa5,0,0); data.diagnostic_ee67=0;
 assert(qcom_flash_external_strobe_set(&v,true)==-ENODEV);
 assert(!module_on && !channels && !ee67_writes); data.diagnostic_ee67=EE67;
 reset(&data,0xa5,0,0); led.flash_current_ma=51;
 assert(qcom_flash_external_strobe_set(&v,true)==-EINVAL);
 assert(!module_on && !channels && !ee67_writes); led.flash_current_ma=50;
 reset(&data,0xa5,0,0); led.flash_timeout_ms=20;
 assert(qcom_flash_external_strobe_set(&v,true)==-EINVAL);
 assert(!module_on && !channels && !ee67_writes); led.flash_timeout_ms=10;
 reset(&data,0xa5,0,0); led.chan_id[1]=2;
 assert(diagnostic_windows_config(&led,true)==-EINVAL);
 led.chan_id[1]=3;
 diagnostic_windows_ee67=false; reset(&data,0xa5,0,0);
 assert(!qcom_flash_external_strobe_set(&v,true));
 assert(ee67==0xa5 && !ee67_writes && !data.diagnostic_saved_valid);
 assert(!qcom_flash_external_strobe_set(&v,false));
 puts("PASS: restore requires readback OFF; limits enforced; opt-out leaves ee67 untouched");
 return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src=Path(tmp)/'test.c'; exe=Path(tmp)/'test'; src.write_text(harness)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
