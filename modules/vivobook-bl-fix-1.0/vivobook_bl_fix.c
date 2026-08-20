// SPDX-License-Identifier: GPL-2.0-only
/* PMK8550 LPG backlight routing for the ASUS Vivobook X1407QA. */

#include <linux/backlight.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/regmap.h>
#include <linux/spmi.h>

#define PMK8550_PATH "/soc@0/arbiter@c400000/spmi@c42d000/pmic@0"
#define LPG_BASE 0xe800
#define LPG_SUBTYPE_REG 0xe805
#define LPG_HI_RES_PWM 0x0c
#define LPG_VALUE_LSB 0xe844
#define LPG_VALUE_MSB 0xe845
#define LPG_SYNC 0xe847
#define LPG_SEC_ACCESS 0xe8d0
#define LPG_DTEST3 0xe8e2
#define LPG_MAX_BRIGHTNESS 4095

static struct backlight_device *vivobook_backlight;
static struct spmi_device *pmk8550;
static struct regmap *pmk8550_regmap;
static unsigned int original_dtest3;
static bool dtest_routed;
static DEFINE_MUTEX(lpg_lock);

static void vivobook_bl_restore_route(void)
{
	int ret;

	if (!dtest_routed)
		return;
	mutex_lock(&lpg_lock);
	ret = regmap_write(pmk8550_regmap, LPG_SEC_ACCESS, 0xa5);
	if (!ret)
		ret = regmap_write(pmk8550_regmap, LPG_DTEST3, original_dtest3);
	mutex_unlock(&lpg_lock);
	if (ret)
		pr_err("vivobook_bl_fix: failed to restore DTEST3: %d\n", ret);
	else
		dtest_routed = false;
}

static int vivobook_bl_write(unsigned int brightness)
{
	int ret;

	brightness = min(brightness, (unsigned int)LPG_MAX_BRIGHTNESS);
	mutex_lock(&lpg_lock);
	ret = regmap_write(pmk8550_regmap, LPG_VALUE_LSB, brightness & 0xff);
	if (!ret)
		ret = regmap_write(pmk8550_regmap, LPG_VALUE_MSB,
				   (brightness >> 8) & 0x0f);
	if (!ret)
		ret = regmap_write(pmk8550_regmap, LPG_SYNC, 1);
	mutex_unlock(&lpg_lock);
	return ret;
}

static int vivobook_bl_update_status(struct backlight_device *bl)
{
	return vivobook_bl_write(backlight_get_brightness(bl));
}

static int vivobook_bl_get_brightness(struct backlight_device *bl)
{
	unsigned int lsb, msb;
	int ret;

	mutex_lock(&lpg_lock);
	ret = regmap_read(pmk8550_regmap, LPG_VALUE_LSB, &lsb);
	if (!ret)
		ret = regmap_read(pmk8550_regmap, LPG_VALUE_MSB, &msb);
	mutex_unlock(&lpg_lock);
	if (ret)
		return ret;
	return ((msb & 0x0f) << 8) | lsb;
}

static const struct backlight_ops vivobook_bl_ops = {
	.options = BL_CORE_SUSPENDRESUME,
	.update_status = vivobook_bl_update_status,
	.get_brightness = vivobook_bl_get_brightness,
};

static int __init vivobook_bl_init(void)
{
	struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.max_brightness = LPG_MAX_BRIGHTNESS,
	};
	struct device_node *pmic_np;
	unsigned int subtype;
	int ret;

	pmic_np = of_find_node_by_path(PMK8550_PATH);
	if (!pmic_np)
		return -ENODEV;
	pmk8550 = spmi_find_device_by_of_node(pmic_np);
	of_node_put(pmic_np);
	if (!pmk8550)
		return -EPROBE_DEFER;

	pmk8550_regmap = dev_get_regmap(&pmk8550->dev, NULL);
	if (!pmk8550_regmap) {
		ret = -EPROBE_DEFER;
		goto put_pmic;
	}
	ret = regmap_read(pmk8550_regmap, LPG_SUBTYPE_REG, &subtype);
	if (ret)
		goto put_pmic;
	if (subtype != LPG_HI_RES_PWM) {
		pr_err("vivobook_bl_fix: unexpected LPG subtype 0x%x\n", subtype);
		ret = -ENODEV;
		goto put_pmic;
	}
	ret = regmap_read(pmk8550_regmap, LPG_DTEST3, &original_dtest3);
	if (ret)
		goto put_pmic;

	/* Only route the existing LPG PWM to DTEST3; never alter PMIC GPIO5. */
	ret = regmap_write(pmk8550_regmap, LPG_SEC_ACCESS, 0xa5);
	if (!ret)
		ret = regmap_write(pmk8550_regmap, LPG_DTEST3, 0x01);
	if (ret)
		goto put_pmic;
	dtest_routed = true;

	ret = vivobook_bl_get_brightness(NULL);
	if (ret < 0)
		goto restore_route;
	props.brightness = ret;
	vivobook_backlight = backlight_device_register("vivobook-backlight",
		&pmk8550->dev, NULL, &vivobook_bl_ops, &props);
	if (IS_ERR(vivobook_backlight)) {
		ret = PTR_ERR(vivobook_backlight);
		vivobook_backlight = NULL;
		goto restore_route;
	}

	backlight_update_status(vivobook_backlight);
	pr_info("vivobook_bl_fix: PMK8550 12-bit backlight registered\n");
	return 0;

restore_route:
	vivobook_bl_restore_route();
put_pmic:
	put_device(&pmk8550->dev);
	pmk8550 = NULL;
	return ret;
}

static void __exit vivobook_bl_exit(void)
{
	backlight_device_unregister(vivobook_backlight);
	vivobook_bl_restore_route();
	put_device(&pmk8550->dev);
}

module_init(vivobook_bl_init);
module_exit(vivobook_bl_exit);

MODULE_AUTHOR("fedora-vivobook-x1407q contributors");
MODULE_DESCRIPTION("ASUS X1407QA PMK8550 LPG backlight fix");
MODULE_LICENSE("GPL");
