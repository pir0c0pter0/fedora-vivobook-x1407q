#!/usr/bin/env python3
"""Compile actual patched C functions against an offline fault-injecting regmap."""
from pathlib import Path
import subprocess
import tempfile
import sys

source = Path(sys.argv[1]).read_text()
def function(name):
    start = source.index('static int ' + name + '(')
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
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
enum led_strobe { SW_STROBE, HW_STROBE };
struct qcom_flash_data { int r_fields[2]; };
struct qcom_flash_led {
 struct qcom_flash_data *flash_data;
 u8 chan_id[2]; int chan_count; bool enabled;
 u32 flash_timeout_ms, flash_current_ma;
};
struct led_classdev_flash { struct qcom_flash_led *led; };
struct v4l2_flash { struct led_classdev_flash *fled_cdev; };
static int event, fail_at, module_on, channels, current_done, timer_done, enable_seen;
static int trip(void) { return ++event == fail_at ? -EIO : 0; }
static int regmap_field_update_bits(int field, int mask, int value) {
 assert(field == REG_CHAN_EN); int rc=trip(); if(rc) return rc;
 if(value) { assert(current_done && timer_done && module_on); enable_seen=1; }
 channels=(channels & ~mask) | value; return 0;
}
static int regmap_fields_write(int field, int channel, int value) {
 assert(field == REG_CHAN_STROBE); assert(channel==0 || channel==3);
 assert(!channels); /* Every source write must follow channel OFF. */
 assert(value==5 || value==1); return trip();
}
static struct qcom_flash_led *flcdev_to_qcom_fled(struct led_classdev_flash *f) {return f->led;}
static int set_flash_module_en(struct qcom_flash_led *l, bool en) {
 (void)l; int rc=trip(); if(rc) return rc;
 if(en) assert(current_done && timer_done && !channels);
 module_on=en; return 0;
}
static int update_allowed_flash_current(struct qcom_flash_led *l,u32 *m,bool en) {
 (void)l; assert(en && *m==50); assert(!channels && !module_on); return trip();
}
static int set_flash_current(struct qcom_flash_led *l,u32 m,int mode) {
 (void)l; assert(m==50 && mode==FLASH_MODE); assert(!channels && !module_on);
 int rc=trip(); if(!rc) current_done=1; return rc;
}
static int set_flash_timeout(struct qcom_flash_led *l,u32 ms) {
 (void)l; assert(ms==10); assert(!channels && !module_on);
 int rc=trip(); if(!rc) timer_done=1; return rc;
}
'''
harness += function('set_flash_strobe') + '\n' + function('qcom_flash_external_strobe_set')
harness += r'''
static void reset(int fail) {
 event=0; fail_at=fail; module_on=1; channels=9;
 current_done=timer_done=enable_seen=0;
}
int main(void) {
 struct qcom_flash_data data={.r_fields={0,1}};
 struct qcom_flash_led led={.flash_data=&data,.chan_id={0,3},.chan_count=2,
   .flash_timeout_ms=10,.flash_current_ma=50};
 struct led_classdev_flash f={.led=&led}; struct v4l2_flash v={.fled_cdev=&f};
 reset(0); assert(!qcom_flash_external_strobe_set(&v,true));
 assert(module_on && channels==9 && led.enabled && enable_seen);
 int events=event;
 for(int failure=1;failure<=events;failure++) {
  reset(failure); assert(qcom_flash_external_strobe_set(&v,true)==-EIO);
  assert(!module_on); /* Failed register may leave chan bits latched, gated off. */
 }
 reset(0); assert(!qcom_flash_external_strobe_set(&v,false));
 assert(!module_on && !channels && !led.enabled && !enable_seen);
 reset(0); led.flash_timeout_ms=0;
 assert(qcom_flash_external_strobe_set(&v,true)==-EINVAL);
 assert(!module_on && !channels && !enable_seen);
 printf("PASS: current/timer before either gate; %d failure positions; OFF; zero timeout rejected\n",events);
 return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src=Path(tmp)/'test.c'; exe=Path(tmp)/'test'; src.write_text(harness)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
