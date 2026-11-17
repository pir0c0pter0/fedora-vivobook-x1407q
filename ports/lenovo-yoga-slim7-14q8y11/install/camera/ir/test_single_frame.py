#!/usr/bin/env python3
"""Offline fault injection of the actual diagnostic stream-enable C function."""
from pathlib import Path
import subprocess
import tempfile
import sys
s=Path(sys.argv[1]).read_text()
a=s.index('static int vd55g0_stream_enable(');b=s.index('\nstatic void vd55g0_save_exposure',a)
fn=s[a:b]
h=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
typedef uint64_t u64;
#define USEC_PER_SEC 1000000
#define DIV_ROUND_UP_ULL(a,b) (((a)+(b)-1)/(b))
#define V4L2_EXPOSURE_MANUAL 1
#define VD55G0_TIMEOUT_MS 500
#define VD55G0_SYSTEM_FSM_STREAMING 3
#define VD55G0_SYSTEM_FSM_SW_STBY 2
#define VD55G0_SW_STBY_START_STREAM 1
enum {VD55G0_REG_STROBE_START_DELAY,VD55G0_REG_STROBE_END_DELAY,
 VD55G0_REG_CONTEXT_REPEAT_COUNT,VD55G0_REG_NEXT_CONTEXT,
 VD55G0_REG_SW_STBY,VD55G0_REG_SYSTEM_FSM,VD55G0_REG_LINE_LENGTH};
struct device{int dummy;}; struct i2c_client{struct device dev;};
struct v4l2_ctrl{int val;struct{int val;}cur;};
struct vd55g0_dev {struct i2c_client *i2c_client;bool diagnostic_consumed;
 struct v4l2_ctrl *expo_ctrl,*ae_ctrl,*hblank_ctrl;int ctrl_handler;};
struct v4l2_subdev_state{int dummy;};
struct v4l2_mbus_framefmt{int dummy;}; struct v4l2_rect{int width;};
static struct v4l2_mbus_framefmt fmt;
static struct v4l2_rect crop={.width=640};
static bool diagnostic_one_frame=true;
static int event,fail_at,starts,powered,corrupt_read;
static u64 regs[7];
static int trip(void){return ++event==fail_at ? -EIO : 0;}
static const struct v4l2_mbus_framefmt *v4l2_subdev_state_get_format(void*s,int p){(void)s;(void)p;return &fmt;}
static const struct v4l2_rect *v4l2_subdev_state_get_crop(void*s,int p){(void)s;(void)p;return &crop;}
static int vd55g0_line_length(void*s){(void)s;return 1200;}
static int vd55g0_pixel_rate(void*s){(void)s;return 140000000;}
static int pm_runtime_resume_and_get(void*d){(void)d;int r=trip();if(!r)powered=1;return r;}
static void pm_runtime_put(void*d){(void)d;powered=0;}
static int vd55g0_disable_gpios(void*s){(void)s;return trip();}
static int vd55g0_apply_frame_format(void*s,const void*f,const void*c){(void)s;(void)f;(void)c;return trip();}
static int vd55g0_apply_cold_start(void*s){(void)s;return trip();}
static int __v4l2_ctrl_handler_setup(void*h){(void)h;return trip();}
static int vd55g0_write(struct vd55g0_dev*s,int reg,u64 val,void*e){
 (void)e;int r=trip();if(r)return r;regs[reg]=val;
 if(reg==VD55G0_REG_SW_STBY){
  assert(powered);
  if(diagnostic_one_frame){
   assert(s->diagnostic_consumed);
   assert(regs[VD55G0_REG_CONTEXT_REPEAT_COUNT]==1);
   assert(regs[VD55G0_REG_NEXT_CONTEXT]==255);
   assert(!regs[VD55G0_REG_STROBE_START_DELAY]&&!regs[VD55G0_REG_STROBE_END_DELAY]);
  }starts++;
 }return 0;
}
static int vd55g0_read(void*s,int reg,u64*v,void*e){(void)s;(void)e;int r=trip();
 if(!r){*v=reg==VD55G0_REG_SYSTEM_FSM ? 2 : regs[reg]+corrupt_read;}return r;}
static int vd55g0_poll_reg(void*s,int r,int v,int t){(void)s;(void)r;(void)v;(void)t;return trip();}
static int vd55g0_wait_state(void*s,int v,int t){(void)s;(void)v;(void)t;return trip();}
'''
h+=fn
h+=r'''
static void reset(int failure){event=0;fail_at=failure;starts=powered=corrupt_read=0;}
int main(void){
 struct i2c_client c;struct v4l2_ctrl expo={.val=1166},ae={.val=1},hb={.cur.val=560};
 struct vd55g0_dev s={.i2c_client=&c,.expo_ctrl=&expo,.ae_ctrl=&ae,.hblank_ctrl=&hb};
 struct v4l2_subdev_state st;
 reset(0);assert(!vd55g0_stream_enable(&s,&st));assert(starts==1&&s.diagnostic_consumed);
 int events=event;
 assert(vd55g0_stream_enable(&s,&st)==-EALREADY);assert(starts==1);
 for(int i=1;i<=events;i++){
  reset(i);s.diagnostic_consumed=false;
  assert(vd55g0_stream_enable(&s,&st)==-EIO);assert(!powered);assert(starts<=1);
 }
 reset(0);s.diagnostic_consumed=false;expo.val=1167;
 assert(vd55g0_stream_enable(&s,&st)==-EINVAL);assert(!starts&&!powered);
 reset(0);expo.val=1166;ae.val=0;
 assert(vd55g0_stream_enable(&s,&st)==-EINVAL);assert(!starts&&!powered);
 reset(0);ae.val=1;corrupt_read=1;
 assert(vd55g0_stream_enable(&s,&st)==-EIO);assert(!starts&&!powered);
 reset(0);diagnostic_one_frame=false;expo.val=1796;ae.val=0;s.diagnostic_consumed=false;
 assert(!vd55g0_stream_enable(&s,&st));assert(!vd55g0_stream_enable(&s,&st));assert(starts==2);
 printf("PASS: single START; readback gates; 1166/1167 line boundary; AE rejected; %d failure positions; baseline repeat preserved\n",events);
}
'''
with tempfile.TemporaryDirectory() as d:
    f=Path(d)/'test.c';o=Path(d)/'test';f.write_text(h)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(f),'-o',str(o)],check=True)
    subprocess.run([str(o)],check=True)
