// SPDX-License-Identifier: GPL-2.0-only
/* ASUS Vivobook X1407QA WCN6855 power hold and delayed PCI rescan. */

#include <linux/delay.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/regulator/consumer.h>
#include <linux/workqueue.h>

#define WCN_VENDOR_ID 0x17cb
#define WCN_DEVICE_ID 0x1103
#define WCN_SUBVENDOR_ID 0x105b
#define WCN_SUBDEVICE_ID 0xe130

static unsigned int rescan_delay_ms = 6000;
module_param(rescan_delay_ms, uint, 0644);
MODULE_PARM_DESC(rescan_delay_ms, "Delay after WCN rails are enabled before PCI rescan");

static unsigned int regulator_retry_ms = 1000;
module_param(regulator_retry_ms, uint, 0644);
MODULE_PARM_DESC(regulator_retry_ms, "Delay before retrying deferred regulator providers");

static unsigned int max_regulator_retries = 30;
module_param(max_regulator_retries, uint, 0644);
MODULE_PARM_DESC(max_regulator_retries, "Maximum retries for deferred regulator providers");

static struct platform_device *consumer_dev;
static bool rails_held;
static unsigned int regulator_retries;

static struct regulator_bulk_data wcn_supplies[] = {
	{ .supply = "vddaon" },
	{ .supply = "vddio" },
	{ .supply = "vddpcie1p3" },
	{ .supply = "vddpcie1p9" },
	{ .supply = "vddpmu" },
	{ .supply = "vddpmucx" },
	{ .supply = "vddpmumx" },
	{ .supply = "vddrfa0p95" },
	{ .supply = "vddrfa1p3" },
	{ .supply = "vddrfa1p9" },
};

static bool wifi_present(void)
{
	struct pci_dev *pdev;

	pdev = pci_get_subsys(WCN_VENDOR_ID, WCN_DEVICE_ID,
			       WCN_SUBVENDOR_ID, WCN_SUBDEVICE_ID, NULL);
	if (!pdev)
		return false;
	pci_dev_put(pdev);
	return true;
}

static void wcn_workfn(struct work_struct *work);
static DECLARE_DELAYED_WORK(wcn_work, wcn_workfn);

static void retry_regulator_get(int ret)
{
	if (regulator_retries >= max_regulator_retries) {
		pr_err("wcn_regulator_fix: regulator retry limit reached after error: %d\n",
		       ret);
		return;
	}

	regulator_retries++;
	pr_info("wcn_regulator_fix: regulator providers not ready: %d (retry %u/%u)\n",
		ret, regulator_retries, max_regulator_retries);
	schedule_delayed_work(&wcn_work,
			      msecs_to_jiffies(regulator_retry_ms));
}

static void wcn_workfn(struct work_struct *work)
{
	struct pci_bus *bus = NULL;
	int ret;

	if (!rails_held) {
		ret = regulator_bulk_get(&consumer_dev->dev,
					 ARRAY_SIZE(wcn_supplies), wcn_supplies);
		if (ret) {
			retry_regulator_get(ret);
			return;
		}

		ret = regulator_bulk_enable(ARRAY_SIZE(wcn_supplies), wcn_supplies);
		if (ret) {
			pr_err("wcn_regulator_fix: failed to enable WCN rails: %d\n", ret);
			regulator_bulk_free(ARRAY_SIZE(wcn_supplies), wcn_supplies);
			retry_regulator_get(ret);
			return;
		}

		rails_held = true;
		pr_info("wcn_regulator_fix: WCN6855 rails held\n");
		schedule_delayed_work(&wcn_work, msecs_to_jiffies(rescan_delay_ms));
		return;
	}

	if (wifi_present()) {
		pr_info("wcn_regulator_fix: WCN6855 already enumerated\n");
		return;
	}

	pci_lock_rescan_remove();
	while ((bus = pci_find_next_bus(bus)))
		pci_rescan_bus(bus);
	pci_unlock_rescan_remove();
	pr_info("wcn_regulator_fix: delayed PCI rescan completed\n");
}

static int __init wcn_regulator_fix_init(void)
{
	struct device_node *pmu_np;

	pmu_np = of_find_compatible_node(NULL, NULL, "qcom,wcn6855-pmu");
	if (!pmu_np)
		return -ENODEV;

	consumer_dev = of_find_device_by_node(pmu_np);
	of_node_put(pmu_np);
	if (!consumer_dev)
		return -EPROBE_DEFER;

	schedule_delayed_work(&wcn_work, 0);
	return 0;
}

static void __exit wcn_regulator_fix_exit(void)
{
	cancel_delayed_work_sync(&wcn_work);
	if (rails_held) {
		regulator_bulk_disable(ARRAY_SIZE(wcn_supplies), wcn_supplies);
		regulator_bulk_free(ARRAY_SIZE(wcn_supplies), wcn_supplies);
	}
	put_device(&consumer_dev->dev);
}

module_init(wcn_regulator_fix_init);
module_exit(wcn_regulator_fix_exit);

MODULE_AUTHOR("fedora-vivobook-x1407q contributors");
MODULE_DESCRIPTION("ASUS X1407QA WCN6855 regulator and PCI rescan fix");
MODULE_SOFTDEP("pre: pwrseq_qcom_wcn");
MODULE_LICENSE("GPL");
