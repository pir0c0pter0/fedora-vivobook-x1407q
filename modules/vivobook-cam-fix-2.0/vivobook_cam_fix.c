/*
 * vivobook_cam_fix.c — Two-phase DT overlay for ASUS Vivobook X1407QA camera
 *
 * Problem: Zenbook A14 DTB (used via bootloader) lacks camera subsystem nodes.
 *          INSYDE firmware blocks all DTB override methods.
 *          Single-phase overlay causes -22 EINVAL when CCI driver probes
 *          during overlay application, conflicting with i2c-bus children.
 *
 * Solution: Two-phase DT overlay at runtime.
 *   Phase 1: Add CAMCC, CCI1 (disabled), CAMSS, regulators, pinctrl
 *            → subsystems probe, CCI1 stays inactive
 *   Phase 2: Enable CCI1 → CCI probe → OV02C10 sensor probe
 *   Hold runtime PM refs as soon as each block appears
 *
 * PLL8 fix: CAMCC uses runtime PM (use_rpm=true). After probe, runtime PM
 * suspends CAMCC, powering off MMCX domain. This LOSES all PLL register
 * configs (L, alpha, config_ctl). When a consumer re-enables a clock,
 * the PLL can't lock because L=0. Fix: hold a pm_runtime ref on CAMCC
 * to prevent suspension.
 *
 * Power topology (from decompiled AeoB firmware — Zenbook A14 patch):
 *   AVDD + DVDD: vreg_l7b_2p8 (PM8550B LDO7, 2.8V)
 *                Camera module has internal LDO for DVDD 1.2V
 *   DOVDD:       vreg_l3m_1p8 (pm8010 RPMH LDO3, 1.8V)
 *                pm8010 physically absent but RPMH fire-and-forget works
 *
 * Bus: CCI1 bus 1 (AON, GPIOs 235/236), sensor addr 0x36
 *
 * Copyright (c) 2026 Pir0c0pter0
 * SPDX-License-Identifier: GPL-2.0
 */

#define pr_fmt(fmt) "vivobook_cam_fix: " fmt

#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/dmi.h>
#include <linux/platform_device.h>
#include <linux/of_platform.h>
#include <linux/pm_runtime.h>

#include "vivobook_cam_phase1.dtbo.h"
#include "vivobook_cam_phase2.dtbo.h"

static int overlay_phase1_id = -1;
static int overlay_phase2_id = -1;
static struct device *held_pm_devs[4];

enum vivobook_cam_pm_target {
	PM_TARGET_CAMCC,
	PM_TARGET_CAMSS,
	PM_TARGET_CCI0,
	PM_TARGET_CCI1,
};

/* DMI match table — only load on ASUS Vivobook */
static const struct dmi_system_id vivobook_cam_dmi[] = {
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "ASUSTeK"),
			DMI_MATCH(DMI_PRODUCT_NAME, "Vivobook"),
		},
	},
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "ASUSTeK"),
			DMI_MATCH(DMI_BOARD_NAME, "X1407QA"),
		},
	},
	{ }
};

static int apply_overlay(const void *blob, unsigned int len, int *id,
			  const char *name)
{
	void *copy;
	int ret;

	copy = kmemdup(blob, len, GFP_KERNEL);
	if (!copy) {
		pr_err("%s: failed to allocate overlay buffer\n", name);
		return -ENOMEM;
	}

	ret = of_overlay_fdt_apply(copy, len, id, NULL);
	if (ret) {
		pr_err("%s: failed to apply overlay: %d\n", name, ret);
		kfree(copy);
		return ret;
	}

	pr_info("%s: overlay applied (id=%d)\n", name, *id);
	return 0;
}

static int hold_runtime_pm_target(const char *path, const char *label,
				  enum vivobook_cam_pm_target target,
				  unsigned int retries, unsigned int delay_ms)
{
	struct device_node *np;
	struct platform_device *pdev;
	int ret;

	if (held_pm_devs[target])
		return 0;

	while (retries--) {
		np = of_find_node_by_path(path);
		if (!np) {
			if (!retries) {
				pr_warn("%s node %s not found\n", label, path);
				return -ENODEV;
			}
			msleep(delay_ms);
			continue;
		}

		pdev = of_find_device_by_node(np);
		of_node_put(np);
		if (!pdev) {
			if (!retries) {
				pr_warn("%s device not ready yet\n", label);
				return -EPROBE_DEFER;
			}
			msleep(delay_ms);
			continue;
		}

		ret = pm_runtime_resume_and_get(&pdev->dev);
		if (ret < 0) {
			put_device(&pdev->dev);
			pr_warn("failed to hold %s runtime PM ref: %d\n",
				label, ret);
			return ret;
		}

		held_pm_devs[target] = &pdev->dev;
		pr_info("holding %s runtime PM ref\n", label);
		return 0;
	}

	return -ENODEV;
}

static void release_runtime_pm_refs(void)
{
	int i;

	for (i = ARRAY_SIZE(held_pm_devs) - 1; i >= 0; i--) {
		if (!held_pm_devs[i])
			continue;

		pm_runtime_put_sync(held_pm_devs[i]);
		put_device(held_pm_devs[i]);
		held_pm_devs[i] = NULL;
	}
}

static int __init vivobook_cam_fix_init(void)
{
	int ret;

	if (!dmi_check_system(vivobook_cam_dmi)) {
		pr_err("not running on ASUS Vivobook — aborting\n");
		return -ENODEV;
	}

	pr_info("applying camera overlays (phase1=%u bytes, phase2=%u bytes)\n",
		vivobook_cam_phase1_dtbo_len,
		vivobook_cam_phase2_dtbo_len);

	/* Phase 1: subsystems + CCI1 disabled */
	ret = apply_overlay(vivobook_cam_phase1_dtbo,
			    vivobook_cam_phase1_dtbo_len,
			    &overlay_phase1_id, "phase1");
	if (ret)
		return ret;

	/*
	 * Grab CAMCC and CAMSS immediately after phase1. A blind sleep here
	 * leaves a large window for CAMCC runtime PM to drop PLL8 state before
	 * the first stream ever happens.
	 */
	ret = hold_runtime_pm_target("/soc@0/clock-controller@ade0000",
				     "CAMCC", PM_TARGET_CAMCC, 20, 50);
	if (ret) {
		pr_err("CAMCC hold failed (%d), removing phase1\n", ret);
		of_overlay_remove(&overlay_phase1_id);
		return ret;
	}

	ret = hold_runtime_pm_target("/soc@0/isp@acb7000",
					     "CAMSS", PM_TARGET_CAMSS, 20, 50);
	if (ret) {
		pr_err("CAMSS hold failed (%d), removing phase1\n", ret);
		release_runtime_pm_refs();
		of_overlay_remove(&overlay_phase1_id);
		return ret;
	}

	/* Phase 2: enable CCI1 → CCI probe → sensor probe */
	ret = apply_overlay(vivobook_cam_phase2_dtbo,
			    vivobook_cam_phase2_dtbo_len,
			    &overlay_phase2_id, "phase2");
	if (ret) {
		pr_err("phase2 failed (%d), removing phase1\n", ret);
		release_runtime_pm_refs();
		of_overlay_remove(&overlay_phase1_id);
		return ret;
	}

	/*
	 * Hold CCI blocks awake once their platform devices exist.
	 * This prevents runtime PM from tearing down shared CPAS/slow AHB
	 * clocks between sensor probe and the first capture.
	 */
	hold_runtime_pm_target("/soc@0/cci@ac15000",
			       "CCI0", PM_TARGET_CCI0, 20, 50);

	ret = hold_runtime_pm_target("/soc@0/cci@ac16000",
				     "CCI1", PM_TARGET_CCI1, 20, 50);
	if (ret) {
		pr_err("CCI1 hold failed (%d), removing overlays\n", ret);
		release_runtime_pm_refs();
		of_overlay_remove(&overlay_phase2_id);
		of_overlay_remove(&overlay_phase1_id);
		return ret;
	}

	pr_info("camera subsystem initialized — OV02C10 should probe on CCI1 bus 1\n");
	return 0;
}

static void __exit vivobook_cam_fix_exit(void)
{
	release_runtime_pm_refs();

	if (overlay_phase2_id >= 0)
		of_overlay_remove(&overlay_phase2_id);
	if (overlay_phase1_id >= 0)
		of_overlay_remove(&overlay_phase1_id);

	pr_info("camera overlays removed\n");
}

module_init(vivobook_cam_fix_init);
module_exit(vivobook_cam_fix_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Pir0c0pter0");
MODULE_DESCRIPTION("Two-phase DT overlay for ASUS Vivobook X1407QA camera (OV02C10)");
MODULE_SOFTDEP("pre: camcc_x1e80100 i2c_qcom_cci qcom_camss ov02c10 v4l2_cci v4l2_fwnode");
