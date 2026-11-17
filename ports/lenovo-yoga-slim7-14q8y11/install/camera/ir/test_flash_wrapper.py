#!/usr/bin/env python3
"""Actual V4L2 s_ctrl/close -> LED callbacks -> register-model integration test.

Arguments: private flash source, unchanged kernel V4L2 wrapper source.
--expect-unrestored reproduces the initial private module's MODE_NONE bug.
No hardware is accessed. Kernel LED dispatch helpers are synchronous mocks.
"""
import ast
from pathlib import Path
import subprocess
import sys
import tempfile

flash_source, wrapper_source = (Path(x).read_text() for x in sys.argv[1:3])
old_bug = '--expect-unrestored' in sys.argv[3:]
# Reuse exactly the fault-injecting register model, without running its tests.
model = ast.parse(Path(__file__).with_name('test_windows_ee67.py').read_text())
harness = next(ast.literal_eval(node.value) for node in model.body
               if isinstance(node, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == 'harness' for t in node.targets))

def function(source, name):
    start = source.index('static ', source.index(name) - 20)
    # Function declarations here have only a one-line static return prefix.
    if source.index(name, start) > source.index('{', start):
        raise ValueError(name)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

harness = harness.replace('#include <errno.h>', '#include <errno.h>\n#include <linux/v4l2-controls.h>')
harness = harness.replace(' u32 flash_timeout_ms, flash_current_ma;',
                          ' u32 flash_timeout_ms, flash_current_ma, max_torch_current_ma;')
harness = harness.replace('struct led_classdev_flash { struct qcom_flash_led *led; };', '''
enum led_brightness { LED_OFF=0, LED_FULL=255 };
#define TORCH_MODE 2
struct led_classdev { struct qcom_flash_led *led; int led_access; };
struct led_classdev_flash { struct qcom_flash_led *led; struct led_classdev led_cdev; };''')
harness = harness.replace('struct v4l2_flash { struct led_classdev_flash *fled_cdev; };', '''
enum { LED_MODE, STROBE_SOURCE, TORCH_INTENSITY };
struct v4l2_ctrl { int id,val; struct v4l2_flash *flash; };
struct v4l2_flash {
 struct led_classdev_flash *fled_cdev; struct v4l2_ctrl *ctrls[3];
 struct led_classdev *iled_cdev;
};
struct v4l2_subdev { struct v4l2_flash *flash; };
struct v4l2_subdev_fh { int vfh; };
static struct led_classdev_flash *lcdev_to_flcdev(struct led_classdev *c);
#define v4l2_ctrl_to_v4l2_flash(c) ((c)->flash)
#define v4l2_subdev_to_v4l2_flash(s) ((s)->flash)
#define v4l2_fh_is_singular(f) (*(f)==1)
#define mutex_lock(l) ((void)(l))
#define mutex_unlock(l) ((void)(l))
#define led_sysfs_enable(c) ((void)(c))
#define call_flash_op(v,op,arg) qcom_flash_##op(v,arg)
''')
harness = harness.replace('assert(mode==FLASH_MODE && !channels && !module_on);',
                          'assert((mode==FLASH_MODE || mode==TORCH_MODE) && !channels && !module_on);')
harness = harness.replace('assert(en && !channels && !module_on);',
                          '(void)en; assert(!channels && !module_on);')
harness += '\nstatic struct led_classdev_flash *active_fled;\n'
harness += 'static struct led_classdev_flash *lcdev_to_flcdev(struct led_classdev *c) { assert(c==&active_fled->led_cdev); return active_fled; }\n'
for name in ('set_flash_strobe','diagnostic_windows_config','diagnostic_external_off',
             'qcom_flash_strobe_set','qcom_flash_led_brightness_set','qcom_flash_external_strobe_set'):
    harness += '\n' + function(flash_source,name)
harness += r'''
static int led_set_brightness_sync(struct led_classdev *c,enum led_brightness v) {
 return qcom_flash_led_brightness_set(c,v);
}
static int led_set_flash_strobe(struct led_classdev_flash *f,bool value) {
 return qcom_flash_strobe_set(f,value);
}
static int led_set_flash_timeout(struct led_classdev_flash *f,u32 value) {
 f->led->flash_timeout_ms=value/1000; return 0;
}
static int led_set_flash_brightness(struct led_classdev_flash *f,u32 value) {
 f->led->flash_current_ma=value/1000; return 0;
}
static int v4l2_flash_set_led_brightness(struct v4l2_flash *v,struct v4l2_ctrl *c) {
 (void)v; (void)c; assert(!"torch/indicator not allowed in this test"); return -EINVAL;
}
'''
for name in ('__software_strobe_mode_inactive','v4l2_flash_s_ctrl'):
    harness += '\n' + function(wrapper_source,name)
harness += r'''
static int v4l2_ctrl_s_ctrl(struct v4l2_ctrl *c,int value) {
 int old=c->val; c->val=value; int rc=v4l2_flash_s_ctrl(c);
 if(rc) c->val=old;
 return rc;
}
'''
harness += '\n' + function(wrapper_source,'v4l2_flash_close')
harness += '\n#define EXPECT_UNRESTORED ' + str(int(old_bug)) + '\n'
harness += r'''
static void reset(struct qcom_flash_data *d) {
 event=fail_at=module_on=channels=current_done=timer_done=enable_seen=0;
 fail_writes_apply=ee67_writes=bad_gate_read=bad_ee67_read=0; ee67=0xa5;
 d->diagnostic_saved_valid=false;
}
int main(void) {
 struct qcom_flash_data d={.r_fields={0,1,2},.diagnostic_ee67=EE67};
 struct qcom_flash_led l={.flash_data=&d,.chan_id={0,3},.chan_count=2,
  .flash_timeout_ms=10,.flash_current_ma=50,.max_torch_current_ma=10};
 struct led_classdev_flash f={.led=&l,.led_cdev={.led=&l}}; active_fled=&f;
 struct v4l2_flash v={.fled_cdev=&f};
 struct v4l2_ctrl mode={.id=V4L2_CID_FLASH_LED_MODE,.flash=&v},
  source={.id=V4L2_CID_FLASH_STROBE_SOURCE,.flash=&v};
 v.ctrls[LED_MODE]=&mode; v.ctrls[STROBE_SOURCE]=&source;
 struct v4l2_subdev sd={.flash=&v}; struct v4l2_subdev_fh fh={.vfh=1};
 reset(&d);
 assert(!v4l2_ctrl_s_ctrl(&source,V4L2_FLASH_STROBE_SOURCE_EXTERNAL));
 assert(!module_on && !channels && ee67==0xa5); /* Source cached in NONE. */
 assert(!v4l2_ctrl_s_ctrl(&mode,V4L2_FLASH_LED_MODE_FLASH));
 assert(module_on && channels==9 && ee67==0xa4);
 event=0;
 assert(!v4l2_ctrl_s_ctrl(&mode,V4L2_FLASH_LED_MODE_NONE));
 int off_events=event;
 assert(!module_on && !channels);
 assert(!v4l2_ctrl_s_ctrl(&source,V4L2_FLASH_STROBE_SOURCE_SOFTWARE));
 assert(!v4l2_flash_close(&sd,&fh));
 if(EXPECT_UNRESTORED) {
  assert(ee67==0xa4 && d.diagnostic_saved_valid);
  puts("REPRODUCED: old MODE_NONE -> SOURCEsoftware -> close leaves ee67 unrestored");
  return 0;
 }
 assert(ee67==0xa5 && !d.diagnostic_saved_valid);
 for(int failure=1;failure<=off_events;failure++) {
  for(int ambiguous=0;ambiguous<2;ambiguous++) {
   reset(&d); mode.val=V4L2_FLASH_LED_MODE_NONE;
   assert(!v4l2_ctrl_s_ctrl(&source,V4L2_FLASH_STROBE_SOURCE_EXTERNAL));
   assert(!v4l2_ctrl_s_ctrl(&mode,V4L2_FLASH_LED_MODE_FLASH));
   event=0; fail_at=failure; fail_writes_apply=ambiguous;
   (void)v4l2_ctrl_s_ctrl(&mode,V4L2_FLASH_LED_MODE_NONE);
   /* Wrapper ignores brightness OFF's return; its strobe OFF then retries.
    * For a failure in the second OFF, retry through the explicit sysfs path. */
   assert(!led_set_flash_strobe(&f,false));
   assert(!led_set_brightness_sync(&f.led_cdev,LED_OFF));
   assert(!module_on && !channels && ee67==0xa5 && !d.diagnostic_saved_valid);
  }
 }
 /* Last-FD close while MODE_FLASH itself invokes external_strobe(false). */
 reset(&d); mode.val=V4L2_FLASH_LED_MODE_NONE;
 assert(!v4l2_ctrl_s_ctrl(&source,V4L2_FLASH_STROBE_SOURCE_EXTERNAL));
 assert(!v4l2_ctrl_s_ctrl(&mode,V4L2_FLASH_LED_MODE_FLASH));
 assert(!v4l2_flash_close(&sd,&fh));
 assert(!module_on && !channels && ee67==0xa5 && !d.diagnostic_saved_valid);
 printf("PASS: actual wrapper MODE_NONE/SOURCE/close; %d OFF failure positions x2; direct close; sysfs retries\n",off_events);
 return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src=Path(tmp)/'test.c'; exe=Path(tmp)/'test'; src.write_text(harness)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
