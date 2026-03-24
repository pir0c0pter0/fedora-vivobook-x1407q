/*
 * vivobook_usb4_fix.c — Experimental USB4/TB3 groundwork for Vivobook X1407QA
 *
 * Current scope:
 *   1. DMI-gated module so experiments never bind on unrelated hardware
 *   2. Register a USB Billboard detector as the trigger for failed TB3 entry
 *   3. Resolve controller -> Type-C port -> PS8833 retimer context
 *   4. Acquire switch/mux/retimer handles for future TB3/USB4 experiments
 *
 * This revision still does NOT enable full USB4/TB3 tunneling.
 * The x1e80100 host/router side is still missing upstream in kernel 6.19.x.
 *
 * SPDX-License-Identifier: GPL-2.0
 */

#define pr_fmt(fmt) "vivobook_usb4_fix: " fmt

#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/usb.h>
#include <linux/usb/pd.h>
#include <linux/usb/pd_vdo.h>
#include <linux/usb/typec.h>
#include <linux/usb/typec_altmode.h>
#include <linux/usb/typec_mux.h>
#include <linux/usb/typec_retimer.h>
#include <linux/usb/typec_tbt.h>
#include <linux/workqueue.h>

#ifndef USB_CLASS_BILLBOARD
#define USB_CLASS_BILLBOARD 0x11
#endif

struct vivobook_usb4_port_ctx {
	const char *port_name;
	const char *controller_name;
	const char *retimer_path;
	struct device_node *retimer_np;
	struct typec_switch *sw;
	struct typec_mux *mux;
	struct typec_retimer *retimer;
	struct device *port_dev;
	struct device *port_tb3_dev;
	struct typec_cable *cable;
	struct device *partner_dev;
	struct typec_altmode *port_tb3_altmode;
	struct typec_altmode *partner_tb3_altmode;
	const struct typec_altmode_ops *port_tb3_orig_ops;
	void *port_tb3_orig_drvdata;
	struct work_struct tb3_work;
	u32 tb3_pending_header;
	bool path_programmed;
};

static bool dry_run = true;
module_param(dry_run, bool, 0644);
MODULE_PARM_DESC(dry_run, "Log actions without touching mux/switch/retimer state");

static bool attempt_usb4;
module_param(attempt_usb4, bool, 0644);
MODULE_PARM_DESC(attempt_usb4, "Attempt TYPEC_MODE_USB4 programming when Billboard is detected");

static int forced_orientation = TYPEC_ORIENTATION_NORMAL;
module_param(forced_orientation, int, 0644);
MODULE_PARM_DESC(forced_orientation, "Forced orientation for experiments: 1=normal 2=reverse");

static bool inject_tb3_altmode = true;
module_param(inject_tb3_altmode, bool, 0644);
MODULE_PARM_DESC(inject_tb3_altmode, "Inject synthetic partner TB3 altmode (SVID 0x8087)");

static bool emulate_tb3_port_ops;
module_param(emulate_tb3_port_ops, bool, 0644);
MODULE_PARM_DESC(emulate_tb3_port_ops,
		 "Install synthetic TB3 port altmode ops (unsafe: may trigger ps883x Oops)");

static char *simulate_controller;
module_param(simulate_controller, charp, 0644);
MODULE_PARM_DESC(simulate_controller, "Run the mapping logic during init for a controller name (e.g. a600000.usb)");

static struct vivobook_usb4_port_ctx vivobook_ports[] = {
	{
		.port_name = "port0",
		.controller_name = "a600000.usb",
		.retimer_path = "/soc@0/geniqup@bc0000/i2c@b8c000/typec-mux@8",
	},
	{
		.port_name = "port1",
		.controller_name = "a800000.usb",
		.retimer_path = "/soc@0/geniqup@bc0000/i2c@b9c000/typec-mux@8",
	},
};

static const struct dmi_system_id vivobook_usb4_dmi[] = {
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

static struct device *vivobook_find_port_consumer(struct device *supplier,
						  const char *port_name)
{
	struct device_link *link;

	if (!supplier)
		return NULL;

	list_for_each_entry(link, &supplier->links.consumers, s_node) {
		if (!link->consumer)
			continue;
		if (strcmp(dev_name(link->consumer), port_name))
			continue;

		return get_device(link->consumer);
	}

	return NULL;
}

static struct typec_partner *vivobook_usb4_partner_from_dev(struct device *dev)
{
	/*
	 * In drivers/usb/typec/class.h, struct typec_partner begins with
	 * struct device dev; the exported partner APIs only need the opaque
	 * pointer, so casting back is sufficient here.
	 */
	return (struct typec_partner *)dev;
}

static struct typec_port *vivobook_usb4_port_from_dev(struct device *dev)
{
	struct {
		unsigned int id;
		struct device dev;
	} *prefix;

	/*
	 * drivers/usb/typec/class.h defines struct typec_port as:
	 *   unsigned int id;
	 *   struct device dev;
	 *   ...
	 * Recover the start address with a matching prefix and cast to the
	 * public opaque type so exported typec_* APIs can consume it.
	 */
	prefix = container_of(dev, typeof(*prefix), dev);
	return (struct typec_port *)prefix;
}

static struct typec_altmode *vivobook_usb4_altmode_from_dev(struct device *dev)
{
	/*
	 * struct typec_altmode begins with struct device dev, so recovering the
	 * opaque handle from the embedded device is sufficient for exported
	 * helpers like typec_altmode_set_ops() and typec_altmode_vdm().
	 */
	return (struct typec_altmode *)dev;
}

static void vivobook_usb4_tb3_port_work(struct work_struct *work)
{
	struct vivobook_usb4_port_ctx *ctx =
		container_of(work, struct vivobook_usb4_port_ctx, tb3_work);
	const struct typec_altmode *partner;
	bool enter;
	int ret;

	if (!ctx->port_tb3_altmode)
		return;

	enter = PD_VDO_CMD(ctx->tb3_pending_header) == CMD_ENTER_MODE;
	ret = typec_altmode_vdm(ctx->port_tb3_altmode, ctx->tb3_pending_header,
				NULL, 1);
	if (ret) {
		pr_warn("%s: synthetic TB3 %s ACK failed: %d\n",
			ctx->port_name, enter ? "enter" : "exit", ret);
		return;
	}

	partner = typec_altmode_get_partner(ctx->port_tb3_altmode);
	typec_altmode_update_active(ctx->port_tb3_altmode, enter);
	if (partner)
		typec_altmode_update_active((struct typec_altmode *)partner, enter);

	pr_info("%s: synthetic TB3 %s ACK delivered\n",
		ctx->port_name, enter ? "enter" : "exit");
}

static int vivobook_usb4_tb3_port_enter(struct typec_altmode *alt, u32 *vdo)
{
	struct vivobook_usb4_port_ctx *ctx = typec_altmode_get_drvdata(alt);
	int svdm_version;

	if (!ctx)
		return -ENODEV;

	svdm_version = typec_altmode_get_svdm_version(alt);
	if (svdm_version < 0)
		svdm_version = SVDM_VER_2_0;

	ctx->tb3_pending_header = VDO(USB_TYPEC_TBT_SID, 1, svdm_version,
				      CMD_ENTER_MODE) |
				 VDO_OPOS(alt->mode) |
				 VDO_CMDT(CMDT_RSP_ACK);
	schedule_work(&ctx->tb3_work);

	pr_info("%s: synthetic port TB3 enter scheduled (enter_vdo=%#x)\n",
		ctx->port_name, vdo ? *vdo : 0);
	return 0;
}

static int vivobook_usb4_tb3_port_exit(struct typec_altmode *alt)
{
	struct vivobook_usb4_port_ctx *ctx = typec_altmode_get_drvdata(alt);
	int svdm_version;

	if (!ctx)
		return -ENODEV;

	svdm_version = typec_altmode_get_svdm_version(alt);
	if (svdm_version < 0)
		svdm_version = SVDM_VER_2_0;

	ctx->tb3_pending_header = VDO(USB_TYPEC_TBT_SID, 1, svdm_version,
				      CMD_EXIT_MODE) |
				 VDO_OPOS(alt->mode) |
				 VDO_CMDT(CMDT_RSP_ACK);
	schedule_work(&ctx->tb3_work);

	pr_info("%s: synthetic port TB3 exit scheduled\n", ctx->port_name);
	return 0;
}

static const struct typec_altmode_ops vivobook_usb4_tb3_port_ops = {
	.enter = vivobook_usb4_tb3_port_enter,
	.exit = vivobook_usb4_tb3_port_exit,
};

static int vivobook_usb4_install_tb3_port_ops(struct vivobook_usb4_port_ctx *ctx)
{
	char altmode_name[32];
	struct typec_altmode *alt;
	struct device *dev;
	int i;

	if (dry_run || !inject_tb3_altmode || !emulate_tb3_port_ops)
		return 0;

	if (!ctx->port_dev)
		return -ENODEV;

	if (ctx->port_tb3_altmode)
		return 0;

	for (i = 0; i < 4; i++) {
		snprintf(altmode_name, sizeof(altmode_name), "%s.%d",
			 ctx->port_name, i);
		dev = device_find_child_by_name(ctx->port_dev, altmode_name);
		if (!dev)
			continue;

		alt = vivobook_usb4_altmode_from_dev(dev);
		if (alt->svid != USB_TYPEC_TBT_SID) {
			put_device(dev);
			continue;
		}

		ctx->port_tb3_dev = dev;
		ctx->port_tb3_altmode = alt;
		break;
	}

	if (!ctx->port_tb3_altmode) {
		pr_warn("%s: local TB3 port altmode not found under %s\n",
			ctx->port_name, dev_name(ctx->port_dev));
		return -ENODEV;
	}

	ctx->port_tb3_orig_ops = ctx->port_tb3_altmode->ops;
	ctx->port_tb3_orig_drvdata = typec_altmode_get_drvdata(ctx->port_tb3_altmode);
	if (ctx->port_tb3_orig_ops && ctx->port_tb3_orig_ops->enter) {
		pr_info("%s: keeping existing port TB3 ops on %s\n",
			ctx->port_name, dev_name(ctx->port_tb3_dev));
		return 0;
	}

	typec_altmode_set_drvdata(ctx->port_tb3_altmode, ctx);
	typec_altmode_set_ops(ctx->port_tb3_altmode, &vivobook_usb4_tb3_port_ops);
	pr_info("%s: installed synthetic port TB3 ops on %s\n",
		ctx->port_name, dev_name(ctx->port_tb3_dev));
	return 0;
}

static int vivobook_usb4_register_synthetic_cable(struct vivobook_usb4_port_ctx *ctx)
{
	struct typec_cable_desc desc = {
		.type = USB_PLUG_TYPE_C,
		.active = 0,
		.identity = NULL,
		.pd_revision = 0,
	};
	struct typec_port *port;

	if (dry_run)
		return 0;

	if (!ctx->port_dev)
		return -ENODEV;

	if (ctx->cable)
		return 0;

	port = vivobook_usb4_port_from_dev(ctx->port_dev);
	ctx->cable = typec_register_cable(port, &desc);
	if (IS_ERR(ctx->cable)) {
		pr_warn("%s: typec_register_cable() failed: %ld\n",
			ctx->port_name, PTR_ERR(ctx->cable));
		ctx->cable = NULL;
		return -EINVAL;
	}

	pr_info("%s: synthetic Type-C cable registered\n", ctx->port_name);
	return 0;
}

static int vivobook_usb4_register_tb3_altmode(struct vivobook_usb4_port_ctx *ctx)
{
	static const struct typec_altmode_desc tb3_desc = {
		.svid = 0x8087,
		.mode = 1,
		.vdo = 0x00000001,
	};
	struct typec_partner *partner;
	char partner_name[32];

	if (dry_run || !inject_tb3_altmode)
		return 0;

	if (!ctx->port_dev)
		return -ENODEV;

	if (!ctx->partner_dev) {
		snprintf(partner_name, sizeof(partner_name), "%s-partner",
			 ctx->port_name);
		ctx->partner_dev = device_find_child_by_name(ctx->port_dev,
							     partner_name);
	}

	if (!ctx->partner_dev) {
		pr_warn("%s: partner device not present\n", ctx->port_name);
		return -ENODEV;
	}

	if (ctx->partner_tb3_altmode)
		return 0;

	partner = vivobook_usb4_partner_from_dev(ctx->partner_dev);
	typec_partner_set_svdm_version(partner, SVDM_VER_2_0);
	typec_partner_set_num_altmodes(partner, 1);

	ctx->partner_tb3_altmode = typec_partner_register_altmode(partner, &tb3_desc);
	if (IS_ERR(ctx->partner_tb3_altmode)) {
		pr_warn("%s: typec_partner_register_altmode(0x8087) failed: %ld\n",
			ctx->port_name, PTR_ERR(ctx->partner_tb3_altmode));
		ctx->partner_tb3_altmode = NULL;
		return -EINVAL;
	}

	pr_info("%s: synthetic TB3 partner altmode registered\n", ctx->port_name);
	return 0;
}

static int vivobook_usb4_prepare_path(struct vivobook_usb4_port_ctx *ctx)
{
	struct enter_usb_data eudo = {
		.eudo = FIELD_PREP(EUDO_USB_MODE_MASK, EUDO_USB_MODE_USB4) |
			FIELD_PREP(EUDO_CABLE_SPEED_MASK, EUDO_CABLE_SPEED_USB4_GEN2) |
			FIELD_PREP(EUDO_CABLE_TYPE_MASK, EUDO_CABLE_TYPE_RE_TIMER),
	};
	struct typec_mux_state mux_state = {
		.alt = NULL,
		.mode = TYPEC_MODE_USB4,
		.data = &eudo,
	};
	struct typec_retimer_state retimer_state = {
		.alt = NULL,
		.mode = TYPEC_MODE_USB4,
		.data = &eudo,
	};
	int ret;

	if (dry_run || !attempt_usb4) {
		pr_info("%s: dry-run only, would program TYPEC_MODE_USB4 on %s\n",
			ctx->port_name, ctx->controller_name);
		return 0;
	}

	if (!ctx->sw || !ctx->mux) {
		pr_warn("%s: missing switch/mux handles\n", ctx->port_name);
		return -ENODEV;
	}

	/*
	 * Orientation is not derived yet from the Type-C core here. Force the
	 * only when experimentation is explicitly enabled.
	 */
	ret = typec_switch_set(ctx->sw, forced_orientation);
	if (ret) {
		pr_warn("%s: typec_switch_set(%d) failed: %d\n",
			ctx->port_name, forced_orientation, ret);
		return ret;
	}

	ret = typec_mux_set(ctx->mux, &mux_state);
	if (ret) {
		pr_warn("%s: typec_mux_set(TYPEC_MODE_USB4) failed: %d\n",
			ctx->port_name, ret);
		return ret;
	}

	if (ctx->retimer) {
		ret = typec_retimer_set(ctx->retimer, &retimer_state);
		if (ret) {
			pr_warn("%s: typec_retimer_set(TYPEC_MODE_USB4) failed: %d\n",
				ctx->port_name, ret);
			return ret;
		}
	}

	ctx->path_programmed = true;
	pr_info("%s: USB4 path programming requested\n", ctx->port_name);
	vivobook_usb4_register_synthetic_cable(ctx);
	vivobook_usb4_install_tb3_port_ops(ctx);
	vivobook_usb4_register_tb3_altmode(ctx);
	return 0;
}

static void vivobook_usb4_reset_path(struct vivobook_usb4_port_ctx *ctx)
{
	struct typec_mux_state mux_state = {
		.alt = NULL,
		.mode = TYPEC_STATE_SAFE,
		.data = NULL,
	};
	struct typec_retimer_state retimer_state = {
		.alt = NULL,
		.mode = TYPEC_STATE_SAFE,
		.data = NULL,
	};

	if (!ctx->path_programmed)
		return;

	if (ctx->retimer)
		typec_retimer_set(ctx->retimer, &retimer_state);
	if (ctx->mux)
		typec_mux_set(ctx->mux, &mux_state);
	if (ctx->sw)
		typec_switch_set(ctx->sw, TYPEC_ORIENTATION_NONE);

	ctx->path_programmed = false;
	pr_info("%s: reset path to SAFE/NONE\n", ctx->port_name);

	cancel_work_sync(&ctx->tb3_work);
	if (ctx->partner_tb3_altmode) {
		typec_unregister_altmode(ctx->partner_tb3_altmode);
		ctx->partner_tb3_altmode = NULL;
	}
	if (ctx->partner_dev) {
		put_device(ctx->partner_dev);
		ctx->partner_dev = NULL;
	}
	if (ctx->cable) {
		typec_unregister_cable(ctx->cable);
		ctx->cable = NULL;
	}
	if (ctx->port_tb3_altmode) {
		typec_altmode_set_ops(ctx->port_tb3_altmode, ctx->port_tb3_orig_ops);
		typec_altmode_set_drvdata(ctx->port_tb3_altmode,
					  ctx->port_tb3_orig_drvdata);
		ctx->port_tb3_altmode = NULL;
		ctx->port_tb3_orig_ops = NULL;
		ctx->port_tb3_orig_drvdata = NULL;
	}
	if (ctx->port_tb3_dev) {
		put_device(ctx->port_tb3_dev);
		ctx->port_tb3_dev = NULL;
	}
}

static struct vivobook_usb4_port_ctx *
vivobook_usb4_resolve_ctx(struct device *controller_dev)
{
	struct vivobook_usb4_port_ctx *ctx;
	struct device *dev;
	int i;

	if (!controller_dev)
		return NULL;

	for (dev = controller_dev; dev; dev = dev->parent) {
		for (i = 0; i < ARRAY_SIZE(vivobook_ports); i++) {
			ctx = &vivobook_ports[i];
			if (strcmp(dev_name(dev), ctx->controller_name))
				continue;

			if (!ctx->port_dev)
				ctx->port_dev = vivobook_find_port_consumer(dev,
									    ctx->port_name);

			return ctx;
		}
	}

	return NULL;
}

static void vivobook_usb4_log_ancestry(struct device *dev)
{
	int depth = 0;

	for (; dev; dev = dev->parent, depth++)
		pr_info("ancestry[%d]=%s\n", depth, dev_name(dev));
}

static struct vivobook_usb4_port_ctx *
vivobook_usb4_resolve_usb_device(struct usb_device *udev)
{
	struct vivobook_usb4_port_ctx *ctx;

	if (!udev || !udev->bus)
		return NULL;

	if (udev->bus->controller) {
		ctx = vivobook_usb4_resolve_ctx(udev->bus->controller);
		if (ctx)
			return ctx;
	}

	if (udev->bus->root_hub) {
		ctx = vivobook_usb4_resolve_ctx(&udev->bus->root_hub->dev);
		if (ctx)
			return ctx;

		ctx = vivobook_usb4_resolve_ctx(udev->bus->root_hub->dev.parent);
		if (ctx)
			return ctx;
	}

	return NULL;
}

static void vivobook_usb4_log_ctx(struct vivobook_usb4_port_ctx *ctx)
{
	pr_info("%s: controller=%s retimer_path=%s switch=%s mux=%s retimer=%s port_dev=%s port_tb3=%s cable=%s partner_dev=%s tb3_altmode=%s\n",
		ctx->port_name,
		ctx->controller_name,
		ctx->retimer_path,
		ctx->sw ? "yes" : "no",
		ctx->mux ? "yes" : "no",
		ctx->retimer ? "yes" : "no",
		ctx->port_dev ? dev_name(ctx->port_dev) : "no",
		ctx->port_tb3_dev ? dev_name(ctx->port_tb3_dev) : "no",
		ctx->cable ? "yes" : "no",
		ctx->partner_dev ? dev_name(ctx->partner_dev) : "no",
		ctx->partner_tb3_altmode ? "yes" : "no");
}

static int vivobook_usb4_setup_ports(void)
{
	struct vivobook_usb4_port_ctx *ctx;
	int i;

	for (i = 0; i < ARRAY_SIZE(vivobook_ports); i++) {
		ctx = &vivobook_ports[i];
		INIT_WORK(&ctx->tb3_work, vivobook_usb4_tb3_port_work);
		ctx->retimer_np = of_find_node_by_path(ctx->retimer_path);
		if (!ctx->retimer_np) {
			pr_warn("%s: retimer DT node not found at %s\n",
				ctx->port_name, ctx->retimer_path);
			continue;
		}

		ctx->sw = fwnode_typec_switch_get(of_fwnode_handle(ctx->retimer_np));
		if (IS_ERR(ctx->sw)) {
			pr_warn("%s: failed to get typec_switch: %ld\n",
				ctx->port_name, PTR_ERR(ctx->sw));
			ctx->sw = NULL;
		}

		ctx->mux = fwnode_typec_mux_get(of_fwnode_handle(ctx->retimer_np));
		if (IS_ERR(ctx->mux)) {
			pr_warn("%s: failed to get typec_mux: %ld\n",
				ctx->port_name, PTR_ERR(ctx->mux));
			ctx->mux = NULL;
		}

		ctx->retimer = fwnode_typec_retimer_get(of_fwnode_handle(ctx->retimer_np));
		if (IS_ERR(ctx->retimer)) {
			pr_warn("%s: failed to get typec_retimer: %ld\n",
				ctx->port_name, PTR_ERR(ctx->retimer));
			ctx->retimer = NULL;
		}

		vivobook_usb4_log_ctx(ctx);
	}

	return 0;
}

static void vivobook_usb4_release_ports(void)
{
	struct vivobook_usb4_port_ctx *ctx;
	int i;

	for (i = 0; i < ARRAY_SIZE(vivobook_ports); i++) {
		ctx = &vivobook_ports[i];
		vivobook_usb4_reset_path(ctx);
		if (ctx->port_dev) {
			put_device(ctx->port_dev);
			ctx->port_dev = NULL;
		}
		if (ctx->retimer) {
			typec_retimer_put(ctx->retimer);
			ctx->retimer = NULL;
		}
		if (ctx->mux) {
			typec_mux_put(ctx->mux);
			ctx->mux = NULL;
		}
		if (ctx->sw) {
			typec_switch_put(ctx->sw);
			ctx->sw = NULL;
		}
		if (ctx->retimer_np) {
			of_node_put(ctx->retimer_np);
			ctx->retimer_np = NULL;
		}
	}
}

static int vivobook_usb4_probe(struct usb_interface *intf,
			       const struct usb_device_id *id)
{
	struct usb_device *udev = interface_to_usbdev(intf);
	struct device *controller_dev = NULL;
	struct vivobook_usb4_port_ctx *ctx;
	const char *controller = "unknown";

	if (udev->bus && udev->bus->controller) {
		controller_dev = udev->bus->controller;
		controller = dev_name(controller_dev);
	}

	dev_info(&intf->dev,
		 "Billboard detected on %s: %04x:%04x, speed=%s, path=%s\n",
		 controller,
		 le16_to_cpu(udev->descriptor.idVendor),
		 le16_to_cpu(udev->descriptor.idProduct),
		 usb_speed_string(udev->speed),
		 dev_name(&udev->dev));

	ctx = vivobook_usb4_resolve_usb_device(udev);
	if (!ctx) {
		dev_warn(&intf->dev, "no Vivobook USB4 context matched controller %s\n",
			 controller);
		if (controller_dev)
			vivobook_usb4_log_ancestry(controller_dev);
		if (udev->bus && udev->bus->root_hub) {
			pr_info("root_hub=%s\n", dev_name(&udev->bus->root_hub->dev));
			if (udev->bus->root_hub->dev.parent)
				vivobook_usb4_log_ancestry(udev->bus->root_hub->dev.parent);
		}
		return 0;
	}

	vivobook_usb4_log_ctx(ctx);
	vivobook_usb4_prepare_path(ctx);

	dev_info(&intf->dev,
		 "TB3 tunnel still depends on missing x1e80100 USB4 host/router support\n");
	return 0;
}

static void vivobook_usb4_disconnect(struct usb_interface *intf)
{
	struct usb_device *udev = interface_to_usbdev(intf);
	struct vivobook_usb4_port_ctx *ctx;

	ctx = vivobook_usb4_resolve_usb_device(udev);
	if (ctx)
		vivobook_usb4_reset_path(ctx);

	dev_info(&intf->dev, "Billboard disconnected\n");
}

static const struct usb_device_id vivobook_usb4_ids[] = {
	{ USB_INTERFACE_INFO(USB_CLASS_BILLBOARD, 0, 0) },
	{ }
};
MODULE_DEVICE_TABLE(usb, vivobook_usb4_ids);

static struct usb_driver vivobook_usb4_driver = {
	.name = "vivobook_usb4_fix",
	.id_table = vivobook_usb4_ids,
	.probe = vivobook_usb4_probe,
	.disconnect = vivobook_usb4_disconnect,
};

static int __init vivobook_usb4_init(void)
{
	int ret;
	int i;

	if (!dmi_check_system(vivobook_usb4_dmi)) {
		pr_err("not running on ASUS Vivobook — aborting\n");
		return -ENODEV;
	}

	pr_info("setting up USB4/TB3 groundwork (dry_run=%d attempt_usb4=%d forced_orientation=%d)\n",
		dry_run, attempt_usb4, forced_orientation);

	ret = vivobook_usb4_setup_ports();
	if (ret)
		return ret;

	if (simulate_controller) {
		struct device *controller_dev;

		controller_dev = bus_find_device_by_name(&platform_bus_type, NULL,
							 simulate_controller);
		for (i = 0; i < ARRAY_SIZE(vivobook_ports); i++) {
			if (strcmp(vivobook_ports[i].controller_name, simulate_controller))
				continue;
			pr_info("simulate_controller=%s -> %s\n",
				simulate_controller, vivobook_ports[i].port_name);
			if (controller_dev) {
				vivobook_usb4_resolve_ctx(controller_dev);
				put_device(controller_dev);
			}
			vivobook_usb4_log_ctx(&vivobook_ports[i]);
			vivobook_usb4_prepare_path(&vivobook_ports[i]);
			break;
		}
	}

	ret = usb_register(&vivobook_usb4_driver);
	if (ret) {
		vivobook_usb4_release_ports();
		return ret;
	}

	pr_info("registered Billboard detector groundwork\n");
	return 0;
}

static void __exit vivobook_usb4_exit(void)
{
	usb_deregister(&vivobook_usb4_driver);
	vivobook_usb4_release_ports();
	pr_info("unregistered Billboard detector\n");
}

module_init(vivobook_usb4_init);
module_exit(vivobook_usb4_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Pir0c0pter0");
MODULE_DESCRIPTION("Experimental USB4/TB3 groundwork for ASUS Vivobook X1407QA");
MODULE_SOFTDEP("pre: pmic_glink_altmode ps883x phy_qcom_qmp_combo ucsi_glink typec_ucsi typec_thunderbolt");
