/*
 * vivobook_color_ctrl.c — CTM-based display color control for Snapdragon X
 *
 * The msm_dpu driver supports CTM (Color Transformation Matrix) via PCC
 * hardware, but does NOT support GAMMA_LUT (hence wl-gammarelay-rs fails).
 * This module commits CTM blobs via the DRM atomic API from kernel space,
 * bypassing the need to be DRM master in userspace.
 *
 * Sysfs interface:
 *   /sys/kernel/vivobook_color/saturation   0.000 – 2.000 (default 1.000)
 *   /sys/kernel/vivobook_color/contrast     0.000 – 2.000 (default 1.000)
 *
 * Device discovery:
 *   Finds "ae00000.display-subsystem" on the platform bus.
 *   msm_drm_private.dev (offset 0) carries the drm_device pointer.
 *   This is a hardware-specific module for the Snapdragon X Vivobook.
 *
 * SPDX-License-Identifier: GPL-2.0
 */

#define pr_fmt(fmt) "vivobook_color_ctrl: " fmt

#include <drm/drm_atomic.h>
#include <drm/drm_crtc.h>
#include <drm/drm_device.h>
#include <drm/drm_drv.h>
#include <drm/drm_file.h>
#include <drm/drm_modeset_lock.h>
#include <drm/drm_property.h>
#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/sysfs.h>
#include <uapi/drm/drm_mode.h>

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("wifiteste");
MODULE_DESCRIPTION("CTM color control for msm_dpu (Snapdragon X eDP)");

/*
 * ae01000.display-controller is the platform device that owns DRM card1.
 * /sys/class/drm/card1/device -> ae01000.display-controller
 */
#define DPU_PLATFORM_DEV "ae01000.display-controller"

/* Saved DRM device reference (acquired at module init) */
static struct drm_device *g_drm_dev;

/* Current settings in milli-units: 1000 = 1.0 */
static int sat_milli = 1000;
static int con_milli = 1000;

static struct kobject *color_kobj;

/* ------------------------------------------------------------------ */
/* CTM matrix computation                                               */
/* ------------------------------------------------------------------ */

/*
 * BT.709 luminance weights × 10000 (sum = 10000).
 * Used to compute the perceptually-correct saturation matrix.
 */
#define LR_W  2126
#define LG_W  7152
#define LB_W   722

/*
 * Convert a matrix element to the u64 value for struct drm_color_ctm.
 *
 * Input: num_100M = element_value × 100,000,000  (s64, may be negative)
 *        con_m   = contrast in milli-units (1000 = 1.0)
 *
 * The DRM CTM uses S31.32 sign-magnitude, but msm_dpu's CONVERT_S3_15 macro
 * has a bug: it strips the sign bit and treats every value as positive,
 * so standard negative encoding produces wrong (too-bright) results.
 *
 * Workaround: encode negative values as a large positive S31.32 number
 * whose lower 18 bits (after >> 17) equal the correct 18-bit 2's complement
 * representation expected by the PCC hardware.
 *
 * For negative value with Q3.15 magnitude hw:
 *   twos_complement = 2^18 - hw
 *   return twos_complement << 17   (positive, driver writes correct bits)
 *
 * For positive value with Q3.15 magnitude hw:
 *   return hw << 17                (standard encoding)
 *
 * Overflow: max hw ≈ 2.0 × 32768 = 65536 = 0x10000
 *   0x30000 << 17 = 0x600000000 ≈ 2.5×10¹⁰  << u64_max  ✓
 */
static u64 make_ctm_coeff(s64 num_100M, s32 con_m)
{
	u64 hw;
	bool neg;
	u64 abs100M;

	num_100M = num_100M * (s64)con_m / 1000LL;

	neg = num_100M < 0;
	abs100M = neg ? (u64)(-num_100M) : (u64)num_100M;

	/* Q3.15: value × 2^15 / 100_000_000 */
	hw = (abs100M << 15) / 100000000ULL;

	if (neg) {
		/* 18-bit 2's complement, encoded as positive trick value */
		u64 twos = (0x40000ULL - hw) & 0x3FFFFULL;
		return twos << 17;
	}
	return hw << 17;
}

/*
 * Build the 3×3 CTM for the given saturation and contrast.
 *
 * Saturation formula (BT.709 luma-preserving mix with identity):
 *   M_diag[i]      = luma_i × (1−s) + s
 *   M_offdiag[i,j] = luma_j × (1−s)
 *
 * Combined: M_final = contrast × M_sat
 *
 * All values internally represented as ×100,000,000 (s64).
 */
static void build_ctm(struct drm_color_ctm *ctm, int sat_m, int con_m)
{
	s32 oms = 1000 - sat_m;          /* one_minus_sat × 1000 */
	s64 br  = (s64)LR_W * oms * 10; /* luma_r × (1−s) × 1e8 */
	s64 bg  = (s64)LG_W * oms * 10;
	s64 bb  = (s64)LB_W * oms * 10;
	s64 sd  = (s64)sat_m * 100000LL; /* s × 1e8 */

	/* Row 0 – R channel output */
	ctm->matrix[0] = make_ctm_coeff(br + sd, con_m);
	ctm->matrix[1] = make_ctm_coeff(bg,      con_m);
	ctm->matrix[2] = make_ctm_coeff(bb,      con_m);
	/* Row 1 – G channel output */
	ctm->matrix[3] = make_ctm_coeff(br,      con_m);
	ctm->matrix[4] = make_ctm_coeff(bg + sd, con_m);
	ctm->matrix[5] = make_ctm_coeff(bb,      con_m);
	/* Row 2 – B channel output */
	ctm->matrix[6] = make_ctm_coeff(br,      con_m);
	ctm->matrix[7] = make_ctm_coeff(bg,      con_m);
	ctm->matrix[8] = make_ctm_coeff(bb + sd, con_m);
}

/* ------------------------------------------------------------------ */
/* DRM device discovery                                                 */
/* ------------------------------------------------------------------ */

/*
 * Walk the children of DPU_PLATFORM_DEV looking for the DRM primary card.
 * DRM registers each card as a child device in the "drm" class.
 * dev_get_drvdata() on the card device returns struct drm_minor *, which
 * carries the drm_device pointer in its public .dev field.
 */
static int find_drm_card_child(struct device *dev, void *data)
{
	struct drm_minor *minor;
	struct drm_device **result = data;

	if (!dev->class || strcmp(dev->class->name, "drm") != 0)
		return 0;

	minor = dev_get_drvdata(dev);
	if (!minor || minor->type != DRM_MINOR_PRIMARY)
		return 0;

	*result = minor->dev;
	return 1; /* stop iteration */
}

/*
 * Returns a new reference (drm_dev_get) that the caller must release
 * with drm_dev_put() when done.
 */
static struct drm_device *find_msm_drm_dev(void)
{
	struct device *pdev;
	struct drm_device *drm_dev = NULL;

	pdev = bus_find_device_by_name(&platform_bus_type, NULL, DPU_PLATFORM_DEV);
	if (!pdev) {
		pr_err("platform device '%s' not found\n", DPU_PLATFORM_DEV);
		return NULL;
	}

	device_for_each_child(pdev, &drm_dev, find_drm_card_child);
	if (drm_dev)
		drm_dev_get(drm_dev);

	put_device(pdev);
	return drm_dev;
}

/* ------------------------------------------------------------------ */
/* DRM atomic commit                                                    */
/* ------------------------------------------------------------------ */

static struct drm_crtc *find_active_crtc(struct drm_device *dev)
{
	struct drm_crtc *crtc;

	drm_for_each_crtc(crtc, dev) {
		if (crtc->state && crtc->state->active)
			return crtc;
	}
	return NULL;
}

static int apply_color(int sat_m, int con_m)
{
	struct drm_modeset_acquire_ctx ctx;
	struct drm_crtc *crtc;
	struct drm_atomic_state *state;
	struct drm_crtc_state *crtc_state;
	struct drm_color_ctm ctm_data;
	struct drm_property_blob *ctm_blob;
	int ret;

	if (!g_drm_dev) {
		pr_err("DRM device not initialised\n");
		return -ENODEV;
	}

	crtc = find_active_crtc(g_drm_dev);
	if (!crtc) {
		pr_err("no active CRTC\n");
		return -ENODEV;
	}

	drm_modeset_acquire_init(&ctx, 0);

	state = drm_atomic_state_alloc(g_drm_dev);
	if (!state) {
		drm_modeset_acquire_fini(&ctx);
		return -ENOMEM;
	}
	state->acquire_ctx = &ctx;

retry:
	crtc_state = drm_atomic_get_crtc_state(state, crtc);
	if (IS_ERR(crtc_state)) {
		ret = PTR_ERR(crtc_state);
		goto backoff;
	}

	/* Drop any existing CTM blob */
	drm_property_blob_put(crtc_state->ctm);
	crtc_state->ctm = NULL;

	if (sat_m == 1000 && con_m == 1000) {
		/* Identity: null CTM = hardware pass-through */
		crtc_state->color_mgmt_changed = true;
		ret = drm_atomic_commit(state);
		goto backoff;
	}

	build_ctm(&ctm_data, sat_m, con_m);

	ctm_blob = drm_property_create_blob(g_drm_dev,
					    sizeof(ctm_data), &ctm_data);
	if (IS_ERR(ctm_blob)) {
		ret = PTR_ERR(ctm_blob);
		goto backoff;
	}

	crtc_state->ctm = ctm_blob;

	/*
	 * _dpu_crtc_setup_cp_blocks() early-returns if color_mgmt_changed
	 * is false. Setting ctm directly (bypassing the property path) does
	 * not set this flag automatically, so we must set it explicitly.
	 */
	crtc_state->color_mgmt_changed = true;

	ret = drm_atomic_commit(state);

backoff:
	if (ret == -EDEADLK) {
		drm_atomic_state_clear(state);
		drm_modeset_backoff(&ctx);
		goto retry;
	}

	drm_atomic_state_put(state);
	drm_modeset_drop_locks(&ctx);
	drm_modeset_acquire_fini(&ctx);
	return ret;
}

/* ------------------------------------------------------------------ */
/* Sysfs attributes                                                     */
/* ------------------------------------------------------------------ */

/*
 * Parse "1.5" / "0.800" / "2" into milli-units (1500 / 800 / 2000).
 * Accepts up to 3 decimal places.  Range: 0.000 – 2.000.
 */
static int parse_milli(const char *buf, int *out)
{
	unsigned long ip;
	unsigned long fp = 0;
	int frac_digits = 0;
	char *end;
	const char *p;

	ip = simple_strtoul(buf, &end, 10);
	p  = end;

	if (*p == '.') {
		p++;
		while (*p >= '0' && *p <= '9' && frac_digits < 3) {
			fp = fp * 10 + (*p - '0');
			frac_digits++;
			p++;
		}
		while (frac_digits < 3) {
			fp *= 10;
			frac_digits++;
		}
	}

	if (ip > 2 || (ip == 2 && fp > 0))
		return -ERANGE;

	*out = (int)(ip * 1000 + fp);
	return 0;
}

static ssize_t saturation_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d.%03d\n", sat_milli / 1000, sat_milli % 1000);
}

static ssize_t saturation_store(struct kobject *kobj,
				 struct kobj_attribute *attr,
				 const char *buf, size_t count)
{
	int val, ret;

	ret = parse_milli(buf, &val);
	if (ret)
		return ret;

	sat_milli = val;
	ret = apply_color(sat_milli, con_milli);
	if (ret)
		return ret;

	pr_info("saturation → %d.%03d\n", sat_milli / 1000, sat_milli % 1000);
	return count;
}

static ssize_t contrast_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d.%03d\n", con_milli / 1000, con_milli % 1000);
}

static ssize_t contrast_store(struct kobject *kobj,
			       struct kobj_attribute *attr,
			       const char *buf, size_t count)
{
	int val, ret;

	ret = parse_milli(buf, &val);
	if (ret)
		return ret;

	con_milli = val;
	ret = apply_color(sat_milli, con_milli);
	if (ret)
		return ret;

	pr_info("contrast → %d.%03d\n", con_milli / 1000, con_milli % 1000);
	return count;
}

static struct kobj_attribute attr_saturation =
	__ATTR(saturation, 0644, saturation_show, saturation_store);

static struct kobj_attribute attr_contrast =
	__ATTR(contrast, 0644, contrast_show, contrast_store);

static struct attribute *color_attrs[] = {
	&attr_saturation.attr,
	&attr_contrast.attr,
	NULL,
};

static struct attribute_group color_attr_group = {
	.attrs = color_attrs,
};

/* ------------------------------------------------------------------ */
/* Module init / exit                                                   */
/* ------------------------------------------------------------------ */

static int __init vivobook_color_ctrl_init(void)
{
	int ret;

	g_drm_dev = find_msm_drm_dev();
	if (!g_drm_dev) {
		pr_err("failed to find msm DRM device\n");
		return -ENODEV;
	}

	color_kobj = kobject_create_and_add("vivobook_color", kernel_kobj);
	if (!color_kobj) {
		drm_dev_put(g_drm_dev);
		return -ENOMEM;
	}

	ret = sysfs_create_group(color_kobj, &color_attr_group);
	if (ret) {
		kobject_put(color_kobj);
		drm_dev_put(g_drm_dev);
		return ret;
	}

	pr_info("loaded — /sys/kernel/vivobook_color/{saturation,contrast}\n");
	return 0;
}

static void __exit vivobook_color_ctrl_exit(void)
{
	apply_color(1000, 1000); /* reset to identity */

	sysfs_remove_group(color_kobj, &color_attr_group);
	kobject_put(color_kobj);
	drm_dev_put(g_drm_dev);
	pr_info("unloaded\n");
}

module_init(vivobook_color_ctrl_init);
module_exit(vivobook_color_ctrl_exit);
