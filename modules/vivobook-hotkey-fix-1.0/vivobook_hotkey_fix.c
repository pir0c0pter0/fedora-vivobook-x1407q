// SPDX-License-Identifier: GPL-2.0-only
/* ASUS X1407QA keyboard handshake and vendor hotkey mapping. */

#include <linux/hid.h>
#include <linux/input.h>
#include <linux/module.h>

#define ASUS_VENDOR_ID 0x0b05
#define X1407QA_KEYBOARD_ID 0x4543
#define ASUS_FEATURE_REPORT_ID 0x5a

static int vivobook_hotkey_handshake(struct hid_device *hdev)
{
	u8 report[] = {
		ASUS_FEATURE_REPORT_ID,
		'A', 'S', 'U', 'S', ' ', 'T', 'e', 'c', 'h', '.', 'I', 'n', 'c', '.', '\0'
	}; /* ASUS Tech.Inc. */

	return hid_hw_raw_request(hdev, ASUS_FEATURE_REPORT_ID, report,
				  sizeof(report), HID_FEATURE_REPORT,
				  HID_REQ_SET_REPORT);
}

#define map_key(code) hid_map_usage_clear(hi, usage, bit, max, EV_KEY, code)
static int vivobook_hotkey_input_mapping(struct hid_device *hdev,
		struct hid_input *hi, struct hid_field *field,
		struct hid_usage *usage, unsigned long **bit, int *max)
{
	if ((usage->hid & HID_USAGE_PAGE) != HID_UP_ASUSVENDOR)
		return 0;

	switch (usage->hid & HID_USAGE) {
	case 0x10:
		map_key(KEY_BRIGHTNESSDOWN);
		break;
	case 0x20:
		map_key(KEY_BRIGHTNESSUP);
		break;
	case 0x7c:
		map_key(KEY_MICMUTE);
		break;
	case 0x82:
		map_key(KEY_CAMERA);
		break;
	case 0x88:
		map_key(KEY_RFKILL);
		break;
	case 0xc7:
		map_key(KEY_KBDILLUMTOGGLE);
		break;
	default:
		return -1;
	}

	set_bit(EV_REP, hi->input->evbit);
	return 1;
}

static int vivobook_hotkey_probe(struct hid_device *hdev,
				 const struct hid_device_id *id)
{
	int ret;

	hdev->quirks |= HID_QUIRK_NO_INIT_REPORTS;
	ret = hid_parse(hdev);
	if (ret)
		return ret;
	ret = hid_hw_start(hdev, HID_CONNECT_DEFAULT);
	if (ret)
		return ret;

	ret = vivobook_hotkey_handshake(hdev);
	if (ret < 0)
		hid_warn(hdev, "ASUS feature handshake failed: %d\n", ret);
	else
		hid_info(hdev, "ASUS X1407QA hotkeys initialized\n");
	return 0;
}

static void vivobook_hotkey_remove(struct hid_device *hdev)
{
	hid_hw_stop(hdev);
}

static int vivobook_hotkey_resume(struct hid_device *hdev)
{
	int ret = vivobook_hotkey_handshake(hdev);

	return ret < 0 ? ret : 0;
}

static const struct hid_device_id vivobook_hotkey_devices[] = {
	{ HID_I2C_DEVICE(ASUS_VENDOR_ID, X1407QA_KEYBOARD_ID) },
	{ }
};
MODULE_DEVICE_TABLE(hid, vivobook_hotkey_devices);

static struct hid_driver vivobook_hotkey_driver = {
	.name = "vivobook_hotkey_fix",
	.id_table = vivobook_hotkey_devices,
	.probe = vivobook_hotkey_probe,
	.remove = vivobook_hotkey_remove,
	.input_mapping = vivobook_hotkey_input_mapping,
	.resume = vivobook_hotkey_resume,
	.reset_resume = vivobook_hotkey_resume,
};
module_hid_driver(vivobook_hotkey_driver);

MODULE_AUTHOR("fedora-vivobook-x1407q contributors");
MODULE_DESCRIPTION("ASUS X1407QA HID hotkey fix");
MODULE_LICENSE("GPL");
