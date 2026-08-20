// SPDX-License-Identifier: GPL-2.0-only
/* Instantiate the ASUS X1407QA keyboard on its real I2C bus. */

#include <linux/hid.h>
#include <linux/i2c.h>
#include <linux/irq.h>
#include <linux/irqdomain.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/pm.h>
#include <linux/workqueue.h>

#define KBD_I2C_PATH "/soc@0/geniqup@bc0000/i2c@b94000"
#define TLMM_PATH "/soc@0/pinctrl@f100000"
#define KBD_I2C_ADDRESS 0x3a
#define KBD_GPIO_IRQ 67
#define KBD_HID_DESCRIPTOR 0x0001

/* Exported by i2c_hid; its private header is not installed for DKMS users. */
struct i2chid_ops {
	int (*power_up)(struct i2chid_ops *ops);
	void (*power_down)(struct i2chid_ops *ops);
	void (*shutdown_tail)(struct i2chid_ops *ops);
	void (*restore_sequence)(struct i2chid_ops *ops);
};

extern int i2c_hid_core_probe(struct i2c_client *client,
			      struct i2chid_ops *ops,
			      u16 hid_descriptor_address, u32 quirks);
extern void i2c_hid_core_remove(struct i2c_client *client);
extern void i2c_hid_core_shutdown(struct i2c_client *client);
extern const struct dev_pm_ops i2c_hid_core_pm;

static struct i2c_client *kbd_client;
static unsigned int kbd_irq;
static struct i2chid_ops kbd_ops;
static unsigned int retry_ms = 1000;
module_param(retry_ms, uint, 0644);
MODULE_PARM_DESC(retry_ms, "Delay while waiting for the I2C/IRQ providers");

static int vivobook_kbd_probe(struct i2c_client *client)
{
	int ret = i2c_hid_core_probe(client, &kbd_ops,
				     KBD_HID_DESCRIPTOR, 0);

	if (ret == -ENXIO || ret == -ENODEV)
		return -EPROBE_DEFER;
	return ret;
}

static void vivobook_kbd_remove(struct i2c_client *client)
{
	i2c_hid_core_remove(client);
}

static const struct i2c_device_id vivobook_kbd_ids[] = {
	{ "vivobook-kbd" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, vivobook_kbd_ids);

static struct i2c_driver vivobook_kbd_driver = {
	.driver = {
		.name = "vivobook-kbd",
		.pm = &i2c_hid_core_pm,
	},
	.probe = vivobook_kbd_probe,
	.remove = vivobook_kbd_remove,
	.shutdown = i2c_hid_core_shutdown,
	.id_table = vivobook_kbd_ids,
};

static void vivobook_kbd_create(struct work_struct *work);
static DECLARE_DELAYED_WORK(kbd_create_work, vivobook_kbd_create);

static void vivobook_kbd_retry(int ret)
{
	pr_info("vivobook_kbd_fix: providers not ready: %d\n", ret);
	schedule_delayed_work(&kbd_create_work, msecs_to_jiffies(retry_ms));
}

static void vivobook_kbd_create(struct work_struct *work)
{
	struct irq_fwspec fwspec = { .param_count = 2 };
	struct i2c_board_info info = {
		I2C_BOARD_INFO("vivobook-kbd", KBD_I2C_ADDRESS),
	};
	struct device_node *adapter_np, *tlmm_np;
	struct i2c_adapter *adapter;
	int ret;

	if (kbd_client)
		return;

	adapter_np = of_find_node_by_path(KBD_I2C_PATH);
	if (!adapter_np) {
		vivobook_kbd_retry(-ENODEV);
		return;
	}
	adapter = of_find_i2c_adapter_by_node(adapter_np);
	of_node_put(adapter_np);
	if (!adapter) {
		vivobook_kbd_retry(-EPROBE_DEFER);
		return;
	}

	if (!kbd_irq) {
		tlmm_np = of_find_node_by_path(TLMM_PATH);
		if (!tlmm_np) {
			ret = -ENODEV;
			goto retry;
		}
		fwspec.fwnode = of_fwnode_handle(tlmm_np);
		fwspec.param[0] = KBD_GPIO_IRQ;
		fwspec.param[1] = IRQ_TYPE_LEVEL_LOW;
		kbd_irq = irq_create_fwspec_mapping(&fwspec);
		of_node_put(tlmm_np);
		if (!kbd_irq) {
			ret = -EPROBE_DEFER;
			goto retry;
		}
	}
	info.irq = kbd_irq;

	kbd_client = i2c_new_client_device(adapter, &info);
	i2c_put_adapter(adapter);
	if (IS_ERR(kbd_client)) {
		ret = PTR_ERR(kbd_client);
		kbd_client = NULL;
		vivobook_kbd_retry(ret);
		return;
	}

	pr_info("vivobook_kbd_fix: keyboard created at 0x%02x, IRQ %u\n",
		KBD_I2C_ADDRESS, kbd_irq);
	return;

retry:
	i2c_put_adapter(adapter);
	vivobook_kbd_retry(ret);
}

static int __init vivobook_kbd_init(void)
{
	int ret;

	ret = i2c_add_driver(&vivobook_kbd_driver);
	if (ret)
		return ret;
	schedule_delayed_work(&kbd_create_work, 0);
	return 0;
}

static void __exit vivobook_kbd_exit(void)
{
	cancel_delayed_work_sync(&kbd_create_work);
	if (kbd_client)
		i2c_unregister_device(kbd_client);
	i2c_del_driver(&vivobook_kbd_driver);
	if (kbd_irq)
		irq_dispose_mapping(kbd_irq);
}

module_init(vivobook_kbd_init);
module_exit(vivobook_kbd_exit);

MODULE_SOFTDEP("pre: i2c_hid vivobook_hotkey_fix");
MODULE_AUTHOR("fedora-vivobook-x1407q contributors");
MODULE_DESCRIPTION("ASUS X1407QA I2C-HID keyboard instantiation fix");
MODULE_LICENSE("GPL");
