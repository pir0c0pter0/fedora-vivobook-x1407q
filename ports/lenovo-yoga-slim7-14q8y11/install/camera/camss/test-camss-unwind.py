#!/usr/bin/env python3
"""Fault-inject actual CAMSS start/stop functions on a four-subdevice pipeline.

Usage: test-camss-unwind.py path/to/camss-video.c
The unpatched source fails: started subdevices survive a later start failure.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
begin = source.find("static void video_stop_subdevices(")
if begin < 0:
    begin = source.index("static int video_start_streaming(")
functions = source[begin:source.index("static void video_unprepare_streaming(")]

stubs = r"""
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define ENOIOCTLCMD 515
#define MEDIA_PAD_FL_SINK 1
#define VB2_BUF_STATE_QUEUED 1
#define VB2_BUF_STATE_ERROR 2
#define dev_err(...) ((void)0)
struct v4l2_subdev;
struct media_entity;
struct media_pad { int flags; struct media_entity *entity; struct media_pad *remote; };
struct media_entity { struct media_pad pads[2]; struct v4l2_subdev *sd; };
struct v4l2_subdev { struct media_entity entity; bool active; int index; };
struct video_device { struct media_entity entity; };
struct camss_video;
struct video_ops { void (*flush_buffers)(struct camss_video *, int); };
struct camss_video { struct video_device vdev; struct video_ops *ops;
 struct { void *dev; } *camss; };
struct vb2_queue { struct camss_video *priv; };
static struct v4l2_subdev nodes[4];
static struct camss_video video;
static struct vb2_queue queue;
static int fail_start, fail_stop, no_op, allocation_error, format_error;
static int starts[4], stops[4], allocations, releases, flushes, flush_state;
static void flush(struct camss_video *v, int state) { ++flushes; flush_state = state; }
static struct video_ops ops = { flush };
static struct camss_video *vb2_get_drv_priv(struct vb2_queue *q) { return q->priv; }
static int video_device_pipeline_alloc_start(struct video_device *v)
{ ++allocations; return allocation_error; }
static void video_device_pipeline_stop(struct video_device *v) { ++releases; }
static int video_check_format(struct camss_video *v) { return format_error; }
static struct media_pad *media_pad_remote_pad_first(struct media_pad *p) { return p->remote; }
static bool is_media_entity_v4l2_subdev(struct media_entity *e) { return !!e->sd; }
static struct v4l2_subdev *media_entity_to_v4l2_subdev(struct media_entity *e) { return e->sd; }
static int call_stream(struct v4l2_subdev *sd, int enable) {
 int i = sd->index;
 if (i == no_op) return -ENOIOCTLCMD;
 /* The real core WARNs and skips setup on duplicate start/stop. */
 assert(sd->active != !!enable);
 if (enable) {
  ++starts[i];
  if (i == fail_start) return -ETIMEDOUT;
 } else ++stops[i];
 sd->active = !!enable;
 return !enable && i == fail_stop ? -EIO : 0;
}
#define v4l2_subdev_call(sd, category, op, enable) call_stream(sd, enable)
static void setup(void) {
 memset(nodes, 0, sizeof(nodes)); memset(&video, 0, sizeof(video));
 memset(starts, 0, sizeof(starts)); memset(stops, 0, sizeof(stops));
 fail_start = fail_stop = no_op = -1;
 allocation_error = format_error = allocations = releases = flushes = flush_state = 0;
 video.ops = &ops; queue.priv = &video;
 video.vdev.entity.pads[0].flags = MEDIA_PAD_FL_SINK;
 video.vdev.entity.pads[0].remote = &nodes[0].entity.pads[1];
 for (int i = 0; i < 4; ++i) {
  nodes[i].index = i; nodes[i].entity.sd = &nodes[i];
  nodes[i].entity.pads[1].entity = &nodes[i].entity;
  if (i < 3) {
   nodes[i].entity.pads[0].flags = MEDIA_PAD_FL_SINK;
   nodes[i].entity.pads[0].remote = &nodes[i+1].entity.pads[1];
  }
 }
}
static void all_stopped(void) {
 for (int i = 0; i < 4; ++i) assert(!nodes[i].active);
}
"""
main = r"""
int main(void) {
 for (int failure = 0; failure < 4; ++failure) {
  setup(); fail_start = failure;
  assert(video_start_streaming(&queue, 4) == -ETIMEDOUT);
  all_stopped();
  assert(allocations == 1 && releases == 1 && flushes == 1);
  assert(flush_state == VB2_BUF_STATE_QUEUED);
  for (int i = 0; i < 4; ++i) {
   assert(starts[i] == (i <= failure)); assert(stops[i] == (i < failure));
  }
  fail_start = -1;
  assert(video_start_streaming(&queue, 4) == 0);
  for (int i = 0; i < 4; ++i) assert(nodes[i].active);
  video_stop_streaming(&queue); all_stopped();
  assert(allocations == 2 && releases == 2 && flushes == 2);
  assert(flush_state == VB2_BUF_STATE_ERROR);
 }
 setup(); allocation_error = -ENOMEM;
 assert(video_start_streaming(&queue, 4) == -ENOMEM);
 assert(releases == 0 && flushes == 1); all_stopped();
 setup(); format_error = -EPIPE;
 assert(video_start_streaming(&queue, 4) == -EPIPE);
 assert(releases == 1 && flushes == 1); all_stopped();
 for (int failure = 0; failure < 4; ++failure) {
  setup(); fail_stop = failure;
  assert(video_start_streaming(&queue, 4) == 0);
  video_stop_streaming(&queue); all_stopped();
  for (int i = 0; i < 4; ++i) assert(stops[i] == 1);
  assert(releases == 1 && flushes == 1);
 }
 setup(); no_op = 1; fail_start = 3;
 assert(video_start_streaming(&queue, 4) == -ETIMEDOUT);
 all_stopped(); assert(stops[0] == 1 && stops[1] == 0 && stops[2] == 1 && stops[3] == 0);
 setup(); fail_start = 3; fail_stop = 0;
 assert(video_start_streaming(&queue, 4) == -ETIMEDOUT);
 all_stopped(); assert(stops[0] == 1 && stops[1] == 1 && stops[2] == 1 && stops[3] == 0);
 puts("PASS: 12 cases; each start position/reopen, alloc/format, stop errors, unsupported op");
}
"""
with tempfile.TemporaryDirectory(prefix="camss-unwind-") as directory:
    test = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    test.write_text(stubs + functions + main)
    subprocess.run(["cc", "-std=gnu11", "-O0", str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
