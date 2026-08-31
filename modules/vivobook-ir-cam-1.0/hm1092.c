// SPDX-License-Identifier: GPL-2.0
/*
 * Himax HM1092 -- sensor IR (Windows Hello) do ASUS Vivobook 14 X1407QA.
 * Monocromatico RAW10, um unico modo 560x360. Estrutura espelhada do
 * ov02c10.c do kernel 7.2 desta maquina (v4l2-cci, subdev state, pm_runtime).
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/property.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/workqueue.h>
#include <media/v4l2-cci.h>
#include <media/v4l2-common.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>

#include "hm1092_ir_sequence.h"
#include "hm1092_regs.h"

#define HM1092_XVCLK			24000000
#define HM1092_LINK_FREQ		180000000ULL
#define HM1092_PIXEL_RATE		36000000

/*
 * O HM1092 nao auto-incrementa o ponteiro de registrador: ler 2 bytes de
 * 0x0000 devolve 0x10,0xff em vez de 0x10,0x91. Por isso todo registrador de
 * 16 bits e tratado como duas metades de 8 bits, e as escritas vao na mesma
 * ordem da sequencia de fabrica: byte baixo primeiro, byte alto depois.
 */
#define HM1092_REG_CHIP_ID_H		CCI_REG8(0x0000)
#define HM1092_REG_CHIP_ID_L		CCI_REG8(0x0001)
#define HM1092_CHIP_ID			0x1091
#define HM1092_REG_STREAM_CONTROL	CCI_REG8(0x0100)

/* Modo unico (CSI-2 1 lane @ 180MHz); casa com a tabela de init. ~29.7 fps. */
#define HM1092_WIDTH			560
#define HM1092_HEIGHT			360
#define HM1092_HTS			1616
#define HM1092_VTS			750
#define HM1092_VTS_MAX			0xffff
#define HM1092_HBLANK			(HM1092_HTS - HM1092_WIDTH)
#define HM1092_VBLANK_MIN		(HM1092_VTS - HM1092_HEIGHT)
#define HM1092_VBLANK_MAX		(HM1092_VTS_MAX - HM1092_HEIGHT)
#define HM1092_REG_VTS_H		CCI_REG8(0x0340)
#define HM1092_REG_VTS_L		CCI_REG8(0x0341)

#define HM1092_REG_EXPOSURE_H		CCI_REG8(0x0202)
#define HM1092_REG_EXPOSURE_L		CCI_REG8(0x0203)
#define HM1092_EXPOSURE_MIN		4
#define HM1092_EXPOSURE_MAX_MARGIN	12
#define HM1092_EXPOSURE_DEFAULT		190

/*
 * 0x0204/0x0205 (ganho analogico SMIA) NAO existe neste sensor: le 0xff nas
 * duas metades, como qualquer registrador nao implementado. O que existe e o
 * ganho digital global em 0x020E/0x020F, formato 8.8 (0x0100 = 1.0x).
 *
 * O campo tem 10 bits: 0x3ff (~4x) e o ultimo valor valido. Medido — de
 * 0x100 ate 0x3ff o brilho sobe monotonico; a partir de 0x400 o sensor passa
 * a emitir frame constante no nivel de preto.
 *
 * Este unico ganho e exposto como V4L2_CID_ANALOGUE_GAIN porque o libcamera
 * trata esse ID como obrigatorio ("Mandatory V4L2 control 0x009e0903 not
 * available" e ele descarta o sensor inteiro). Nao ha ganho analogico separado
 * para expor no lugar.
 */
#define HM1092_REG_GAIN_H		CCI_REG8(0x020e)
#define HM1092_REG_GAIN_L		CCI_REG8(0x020f)
#define HM1092_GAIN_UNITY		0x0100

/* Grouped parameter hold: a sequencia de fabrica escreve 1 e depois 0 em volta
 * do bloco de parametros, e foi a unica escrita que produziu mudanca medivel
 * na imagem. Entao todo write de controle vai dentro do hold. */
#define HM1092_REG_GROUP_HOLD		CCI_REG8(0x0104)
#define HM1092_GAIN_MAX			0x3ff
#define HM1092_IR_RETRY_DELAY_MS	250

#define HM1092_FLASH_BASE		0xee00
#define HM1092_FLASH_MODULE_ENABLE	0x46
#define HM1092_FLASH_CHANNEL_ENABLE	0x4e
#define HM1092_FLASH_MODULE_MASK	BIT(7)
#define HM1092_FLASH_CHANNEL_MASK	(BIT(0) | BIT(3))

/* O BSP oficial da ASUS limita o emissor a 700mA; o DT aplica esse teto. */
static unsigned int ir_led_brightness = LED_FULL;
module_param(ir_led_brightness, uint, 0644);
MODULE_PARM_DESC(ir_led_brightness,
		 "IR brightness (0-255; full scale is capped at 700mA by DT)");

/* Escreve um valor de 16 bits em duas metades: baixo primeiro, como o
 * driver de fabrica faz (o sensor nao auto-incrementa). */
static void hm1092_write_pair(struct regmap *regmap, u32 reg_h, u32 reg_l,
			      u16 val, int *err)
{
	cci_write(regmap, reg_l, val & 0xff, err);
	cci_write(regmap, reg_h, val >> 8, err);
}

static const s64 link_freq_menu_items[] = {
	HM1092_LINK_FREQ,
};

/* Sem dvdd: o modulo tem LDO interno. */
static const char * const hm1092_supply_names[] = {
	"dovdd",	/* 1.8V, pm8010 LDO4 */
	"avdd",		/* 2.912V, pm8010 LDO7 */
};

struct hm1092 {
	struct device *dev;
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrl_handler;
	struct regmap *regmap;
	struct v4l2_ctrl *exposure;

	struct clk *xvclk;
	struct gpio_desc *reset;
	struct led_classdev *ir_led;
	struct regmap *ir_provider_regmap;
	u32 ir_provider_base;
	bool streaming;
	bool cleanup_pending;
	bool cleanup_stop_sensor;
	bool cleanup_release_pm;
	bool cleanup_restore_stream;
	bool removing;
	struct delayed_work ir_cleanup_work;
	struct regulator_bulk_data supplies[ARRAY_SIZE(hm1092_supply_names)];
};

static inline struct hm1092 *to_hm1092(struct v4l2_subdev *subdev)
{
	return container_of(subdev, struct hm1092, sd);
}

static int hm1092_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct hm1092 *hm1092 = container_of(ctrl->handler, struct hm1092,
					     ctrl_handler);
	s64 exposure_max;
	int ret = 0;

	/* VBLANK muda o frame length, logo o teto da exposicao. */
	if (ctrl->id == V4L2_CID_VBLANK) {
		exposure_max = HM1092_HEIGHT + ctrl->val -
			       HM1092_EXPOSURE_MAX_MARGIN;
		__v4l2_ctrl_modify_range(hm1092->exposure,
					 hm1092->exposure->minimum,
					 exposure_max, hm1092->exposure->step,
					 hm1092->exposure->default_value);
	}

	/* So escreve no sensor se ele ja estiver ligado. */
	if (!pm_runtime_get_if_in_use(hm1092->dev))
		return 0;

	cci_write(hm1092->regmap, HM1092_REG_GROUP_HOLD, 1, &ret);

	switch (ctrl->id) {
	case V4L2_CID_ANALOGUE_GAIN:
		hm1092_write_pair(hm1092->regmap, HM1092_REG_GAIN_H,
				  HM1092_REG_GAIN_L, ctrl->val, &ret);
		break;
	case V4L2_CID_EXPOSURE:
		hm1092_write_pair(hm1092->regmap, HM1092_REG_EXPOSURE_H,
				  HM1092_REG_EXPOSURE_L, ctrl->val, &ret);
		break;
	case V4L2_CID_VBLANK:
		hm1092_write_pair(hm1092->regmap, HM1092_REG_VTS_H,
				  HM1092_REG_VTS_L, HM1092_HEIGHT + ctrl->val,
				  &ret);
		break;
	default:
		ret = -EINVAL;
		break;
	}

	cci_write(hm1092->regmap, HM1092_REG_GROUP_HOLD, 0, &ret);

	pm_runtime_put(hm1092->dev);
	return ret;
}

static const struct v4l2_ctrl_ops hm1092_ctrl_ops = {
	.s_ctrl = hm1092_set_ctrl,
};

static int hm1092_init_controls(struct hm1092 *hm1092)
{
	struct v4l2_ctrl_handler *ctrl_hdlr = &hm1092->ctrl_handler;
	struct v4l2_fwnode_device_properties props;
	struct v4l2_ctrl *ctrl;
	int ret;

	v4l2_ctrl_handler_init(ctrl_hdlr, 8);

	/* Modo unico: link freq, pixel rate e hblank sao fixos. */
	ctrl = v4l2_ctrl_new_int_menu(ctrl_hdlr, &hm1092_ctrl_ops,
				      V4L2_CID_LINK_FREQ,
				      ARRAY_SIZE(link_freq_menu_items) - 1, 0,
				      link_freq_menu_items);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	ctrl = v4l2_ctrl_new_std(ctrl_hdlr, &hm1092_ctrl_ops,
				 V4L2_CID_PIXEL_RATE, HM1092_PIXEL_RATE,
				 HM1092_PIXEL_RATE, 1, HM1092_PIXEL_RATE);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	ctrl = v4l2_ctrl_new_std(ctrl_hdlr, &hm1092_ctrl_ops, V4L2_CID_HBLANK,
				 HM1092_HBLANK, HM1092_HBLANK, 1,
				 HM1092_HBLANK);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	v4l2_ctrl_new_std(ctrl_hdlr, &hm1092_ctrl_ops, V4L2_CID_VBLANK,
			  HM1092_VBLANK_MIN, HM1092_VBLANK_MAX, 1,
			  HM1092_VBLANK_MIN);

	hm1092->exposure = v4l2_ctrl_new_std(ctrl_hdlr, &hm1092_ctrl_ops,
					     V4L2_CID_EXPOSURE,
					     HM1092_EXPOSURE_MIN,
					     HM1092_VTS -
					     HM1092_EXPOSURE_MAX_MARGIN, 1,
					     HM1092_EXPOSURE_DEFAULT);

	v4l2_ctrl_new_std(ctrl_hdlr, &hm1092_ctrl_ops, V4L2_CID_ANALOGUE_GAIN,
			  HM1092_GAIN_UNITY, HM1092_GAIN_MAX, 1,
			  HM1092_GAIN_UNITY);

	ret = v4l2_fwnode_device_parse(hm1092->dev, &props);
	if (ret)
		return ret;

	v4l2_ctrl_new_fwnode_properties(ctrl_hdlr, &hm1092_ctrl_ops, &props);

	if (ctrl_hdlr->error)
		return ctrl_hdlr->error;

	hm1092->sd.ctrl_handler = ctrl_hdlr;
	return 0;
}

static void hm1092_update_pad_format(struct v4l2_mbus_framefmt *fmt)
{
	fmt->width = HM1092_WIDTH;
	fmt->height = HM1092_HEIGHT;
	/* Sensor IR monocromatico: RAW10 (CSI-2 DT 0x2b) sem padrao Bayer. */
	fmt->code = MEDIA_BUS_FMT_Y10_1X10;
	fmt->colorspace = V4L2_COLORSPACE_RAW;
	fmt->field = V4L2_FIELD_NONE;
}

static int hm1092_sensor_set(void *context, bool on)
{
	struct hm1092 *hm1092 = context;

	return cci_write(hm1092->regmap, HM1092_REG_STREAM_CONTROL, on, NULL);
}

static int hm1092_illuminator_set(void *context, bool on)
{
	struct hm1092 *hm1092 = context;
	unsigned int brightness;

	brightness = on ? min(ir_led_brightness, (unsigned int)LED_FULL) :
			  LED_OFF;
	return led_set_brightness_sync(hm1092->ir_led, brightness);
}

static int hm1092_provider_force_ir_off(void *context)
{
	struct hm1092 *hm1092 = context;
	unsigned int channels = ~0U, module = ~0U;
	int attempt, channel_ret, module_ret, read_channel_ret, read_module_ret;
	int ret = -EIO;

	for (attempt = 0; attempt < HM1092_IR_OFF_ATTEMPTS; attempt++) {
		channel_ret = regmap_update_bits(hm1092->ir_provider_regmap,
				hm1092->ir_provider_base +
				HM1092_FLASH_CHANNEL_ENABLE,
				HM1092_FLASH_CHANNEL_MASK, 0);
		module_ret = regmap_update_bits(hm1092->ir_provider_regmap,
				hm1092->ir_provider_base +
				HM1092_FLASH_MODULE_ENABLE,
				HM1092_FLASH_MODULE_MASK, 0);
		read_channel_ret = regmap_read(hm1092->ir_provider_regmap,
				hm1092->ir_provider_base +
				HM1092_FLASH_CHANNEL_ENABLE, &channels);
		read_module_ret = regmap_read(hm1092->ir_provider_regmap,
				hm1092->ir_provider_base +
				HM1092_FLASH_MODULE_ENABLE, &module);

		if (!read_channel_ret && !read_module_ret &&
		    !(channels & HM1092_FLASH_CHANNEL_MASK) &&
		    !(module & HM1092_FLASH_MODULE_MASK)) {
			hm1092->ir_led->brightness = LED_OFF;
			return 0;
		}

		if (channel_ret)
			ret = channel_ret;
		else if (module_ret)
			ret = module_ret;
		else if (read_channel_ret)
			ret = read_channel_ret;
		else if (read_module_ret)
			ret = read_module_ret;
		else
			ret = -EIO;
	}

	dev_emerg(hm1092->dev,
		  "PM8550 IR off could not be proved: channels=%02x module=%02x ret=%d\n",
		  channels & 0xff, module & 0xff, ret);
	return ret;
}

static int hm1092_sensor_power_off(void *context)
{
	struct hm1092 *hm1092 = context;

	gpiod_set_value_cansleep(hm1092->reset, 1);
	clk_disable_unprepare(hm1092->xvclk);
	/* bulk_disable desliga na ordem inversa: avdd, depois dovdd. */
	return regulator_bulk_disable(ARRAY_SIZE(hm1092_supply_names),
				      hm1092->supplies);
}

static int hm1092_sensor_power_restore(void *context)
{
	struct hm1092 *hm1092 = context;
	int ret;

	/* regulator_bulk_disable() re-enables earlier rails before an error. */
	ret = clk_prepare_enable(hm1092->xvclk);
	if (ret) {
		dev_emerg(hm1092->dev,
			  "failed to restore clock after power-off error: %d\n",
			  ret);
		return ret;
	}

	usleep_range(1000, 1200);
	gpiod_set_value_cansleep(hm1092->reset, 0);
	usleep_range(10000, 10500);
	return 0;
}

static const struct hm1092_ir_ops hm1092_ir_ops = {
	.sensor_set = hm1092_sensor_set,
	.illuminator_set = hm1092_illuminator_set,
	.provider_force_off = hm1092_provider_force_ir_off,
	.sensor_power_off = hm1092_sensor_power_off,
	.sensor_power_restore = hm1092_sensor_power_restore,
};

static int hm1092_force_ir_off(struct hm1092 *hm1092, const char *reason)
{
	int ret;

	ret = hm1092_ir_force_off(&hm1092_ir_ops, hm1092);
	if (ret)
		dev_err_ratelimited(hm1092->dev,
				"failed to force IR illuminator off during %s after %u attempts: %d\n",
				reason, HM1092_IR_OFF_ATTEMPTS, ret);

	return ret;
}

static int hm1092_teardown_ir_off(struct hm1092 *hm1092,
				   const char *reason)
{
	int ret;

	ret = hm1092_ir_teardown_off(&hm1092_ir_ops, hm1092);
	if (ret)
		dev_emerg(hm1092->dev,
			  "IR illuminator off is unresolved during %s: %d\n",
			  reason, ret);

	return ret;
}

static int hm1092_start_streaming_hw(struct hm1092 *hm1092,
				      bool *sensor_active)
{
	int ret;

	lockdep_assert_held(hm1092->sd.state_lock);
	*sensor_active = false;

	ret = cci_multi_reg_write(hm1092->regmap, hm1092_init_regs,
				  ARRAY_SIZE(hm1092_init_regs), NULL);
	if (ret) {
		dev_err(hm1092->dev, "failed to set mode\n");
		return ret;
	}

	ret = __v4l2_ctrl_handler_setup(hm1092->sd.ctrl_handler);
	if (ret)
		return ret;

	return hm1092_ir_start(&hm1092_ir_ops, hm1092, sensor_active);
}

static void hm1092_schedule_ir_cleanup(struct hm1092 *hm1092,
					bool stop_sensor, bool release_pm,
					bool restore_stream)
{
	lockdep_assert_held(hm1092->sd.state_lock);
	if (hm1092->removing)
		return;

	hm1092->cleanup_pending = true;
	hm1092->cleanup_stop_sensor = stop_sensor;
	hm1092->cleanup_release_pm = release_pm;
	hm1092->cleanup_restore_stream = restore_stream;
	mod_delayed_work(system_freezable_wq, &hm1092->ir_cleanup_work,
			 msecs_to_jiffies(HM1092_IR_RETRY_DELAY_MS));
}

static void hm1092_ir_cleanup_worker(struct work_struct *work)
{
	struct hm1092 *hm1092 = container_of(to_delayed_work(work),
						 struct hm1092, ir_cleanup_work);
	bool release_pm = false, retry = false, sensor_active;
	int ret;

	mutex_lock(hm1092->sd.state_lock);
	if (!hm1092->cleanup_pending)
		goto unlock;

	if (hm1092->cleanup_restore_stream) {
		if (hm1092->cleanup_stop_sensor) {
			ret = hm1092_force_ir_off(hm1092,
						  "stream restore cleanup");
			if (ret) {
				retry = true;
				goto unlock;
			}
			ret = hm1092_sensor_set(hm1092, false);
			if (ret) {
				retry = true;
				goto unlock;
			}
			hm1092->cleanup_stop_sensor = false;
		}

		ret = hm1092_start_streaming_hw(hm1092, &sensor_active);
		if (ret) {
			hm1092->cleanup_stop_sensor = sensor_active;
			retry = true;
			goto unlock;
		}
		goto complete;
	}

	ret = hm1092_force_ir_off(hm1092, "deferred cleanup");
	if (ret) {
		retry = true;
		goto unlock;
	}

	if (hm1092->cleanup_stop_sensor) {
		ret = hm1092_sensor_set(hm1092, false);
		if (ret) {
			dev_err_ratelimited(hm1092->dev,
					"failed to stop sensor during deferred IR cleanup: %d\n",
					ret);
			retry = true;
			goto unlock;
		}
	}

complete:
	release_pm = hm1092->cleanup_release_pm;
	if (release_pm)
		hm1092->streaming = false;
	hm1092->cleanup_pending = false;
	hm1092->cleanup_stop_sensor = false;
	hm1092->cleanup_release_pm = false;
	hm1092->cleanup_restore_stream = false;

unlock:
	retry = retry && !hm1092->removing;
	mutex_unlock(hm1092->sd.state_lock);

	if (release_pm)
		pm_runtime_put(hm1092->dev);
	if (retry)
		mod_delayed_work(system_freezable_wq, &hm1092->ir_cleanup_work,
				 msecs_to_jiffies(HM1092_IR_RETRY_DELAY_MS));
}

static int hm1092_enable_streams(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state,
				 u32 pad, u64 streams_mask)
{
	struct hm1092 *hm1092 = to_hm1092(sd);
	bool sensor_active;
	int ret;

	if (hm1092->removing || hm1092->cleanup_pending)
		return -EBUSY;

	ret = pm_runtime_resume_and_get(hm1092->dev);
	if (ret)
		return ret;

	ret = hm1092_start_streaming_hw(hm1092, &sensor_active);
	if (!ret)
		hm1092->streaming = true;
	else if (sensor_active)
		hm1092_schedule_ir_cleanup(hm1092, true, true, false);
	else
		pm_runtime_put(hm1092->dev);
	return ret;
}

static int hm1092_disable_streams(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  u32 pad, u64 streams_mask)
{
	struct hm1092 *hm1092 = to_hm1092(sd);
	int ret;

	if (!hm1092->streaming && !hm1092->cleanup_pending)
		return 0;

	ret = hm1092_ir_stop(&hm1092_ir_ops, hm1092);
	if (ret) {
		hm1092_schedule_ir_cleanup(hm1092, true, true, false);
		dev_warn_ratelimited(hm1092->dev,
				"stream stop deferred after hardware error: %d\n",
				ret);
		return 0;
	}

	hm1092->streaming = false;
	hm1092->cleanup_pending = false;
	cancel_delayed_work(&hm1092->ir_cleanup_work);
	pm_runtime_put(hm1092->dev);
	return 0;
}

static int hm1092_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm1092 = to_hm1092(sd);

	return hm1092_ir_power_off(&hm1092_ir_ops, hm1092);
}

static int hm1092_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm1092 = to_hm1092(sd);
	int ret;

	/* Ordem obrigatoria: dovdd, avdd, xvclk, ~1ms, solta reset, ~10ms. */
	ret = regulator_bulk_enable(ARRAY_SIZE(hm1092_supply_names),
				    hm1092->supplies);
	if (ret < 0) {
		dev_err(dev, "failed to enable regulators: %d\n", ret);
		return ret;
	}

	ret = clk_prepare_enable(hm1092->xvclk);
	if (ret < 0) {
		dev_err(dev, "failed to enable xvclk: %d\n", ret);
		regulator_bulk_disable(ARRAY_SIZE(hm1092_supply_names),
				       hm1092->supplies);
		return ret;
	}

	usleep_range(1000, 1200);
	gpiod_set_value_cansleep(hm1092->reset, 0);
	usleep_range(10000, 10500);	return 0;
}

static int hm1092_enum_mbus_code(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *sd_state,
				 struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;

	code->code = MEDIA_BUS_FMT_Y10_1X10;
	return 0;
}

static int hm1092_enum_frame_size(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *sd_state,
				  struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index > 0 || fse->code != MEDIA_BUS_FMT_Y10_1X10)
		return -EINVAL;

	fse->min_width = HM1092_WIDTH;
	fse->max_width = HM1092_WIDTH;
	fse->min_height = HM1092_HEIGHT;
	fse->max_height = HM1092_HEIGHT;
	return 0;
}

/* Sem .get_selection o camss do 7.2 reclama de static properties. */
static int hm1092_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *state,
				struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_BOUNDS:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_NATIVE_SIZE:
		sel->r = (struct v4l2_rect) {
			.width = HM1092_WIDTH,
			.height = HM1092_HEIGHT,
		};
		return 0;
	default:
		return -EINVAL;
	}
}

static int hm1092_init_state(struct v4l2_subdev *sd,
			     struct v4l2_subdev_state *sd_state)
{
	hm1092_update_pad_format(v4l2_subdev_state_get_format(sd_state, 0));
	return 0;
}

static const struct v4l2_subdev_video_ops hm1092_video_ops = {
	.s_stream = v4l2_subdev_s_stream_helper,
};

static const struct v4l2_subdev_pad_ops hm1092_pad_ops = {
	/* Formato fixo: S_FMT devolve o unico formato posto por init_state. */
	.set_fmt = v4l2_subdev_get_fmt,
	.get_fmt = v4l2_subdev_get_fmt,
	.enum_mbus_code = hm1092_enum_mbus_code,
	.enum_frame_size = hm1092_enum_frame_size,
	.get_selection = hm1092_get_selection,
	.enable_streams = hm1092_enable_streams,
	.disable_streams = hm1092_disable_streams,
};

static const struct v4l2_subdev_ops hm1092_subdev_ops = {
	.video = &hm1092_video_ops,
	.pad = &hm1092_pad_ops,
};

static const struct media_entity_operations hm1092_subdev_entity_ops = {
	.link_validate = v4l2_subdev_link_validate,
};

static const struct v4l2_subdev_internal_ops hm1092_internal_ops = {
	.init_state = hm1092_init_state,
};

static int hm1092_identify_module(struct hm1092 *hm1092)
{
	u64 hi, lo;
	u16 chip_id;
	int ret = 0;

	cci_read(hm1092->regmap, HM1092_REG_CHIP_ID_H, &hi, &ret);
	cci_read(hm1092->regmap, HM1092_REG_CHIP_ID_L, &lo, &ret);
	if (ret)
		return ret;

	chip_id = (hi << 8) | lo;
	if (chip_id != HM1092_CHIP_ID) {
		dev_err(hm1092->dev, "chip id mismatch: %x!=%x\n",
			HM1092_CHIP_ID, chip_id);
		return -ENXIO;
	}
	return 0;
}

static void hm1092_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct hm1092 *hm1092 = to_hm1092(sd);
	bool release_pm;
	int power_ret = 0, ret, sensor_ret = 0;

	mutex_lock(hm1092->sd.state_lock);
	hm1092->removing = true;
	mutex_unlock(hm1092->sd.state_lock);
	v4l2_async_unregister_subdev(sd);
	cancel_delayed_work_sync(&hm1092->ir_cleanup_work);

	mutex_lock(hm1092->sd.state_lock);
	release_pm = hm1092->streaming || hm1092->cleanup_release_pm;
	ret = hm1092_teardown_ir_off(hm1092, "remove");
	if (!ret && (hm1092->streaming || hm1092->cleanup_pending)) {
		sensor_ret = hm1092_sensor_set(hm1092, false);
		if (sensor_ret)
			dev_err(hm1092->dev,
				"failed to stop sensor during remove: %d\n",
				sensor_ret);
	}
	if (!ret && !sensor_ret) {
		hm1092->streaming = false;
		hm1092->cleanup_pending = false;
		hm1092->cleanup_release_pm = false;
		hm1092->cleanup_restore_stream = false;
	}
	mutex_unlock(hm1092->sd.state_lock);

	pm_runtime_disable(hm1092->dev);
	if (!pm_runtime_status_suspended(hm1092->dev)) {
		power_ret = hm1092_power_off(hm1092->dev);
		if (!power_ret)
			pm_runtime_set_suspended(hm1092->dev);
		else
			hm1092_teardown_ir_off(hm1092,
						"failed remove power-off");
	}
	if (!power_ret) {
		mutex_lock(hm1092->sd.state_lock);
		hm1092->streaming = false;
		hm1092->cleanup_pending = false;
		hm1092->cleanup_release_pm = false;
		hm1092->cleanup_restore_stream = false;
		mutex_unlock(hm1092->sd.state_lock);
	}
	if (release_pm)
		pm_runtime_put_noidle(hm1092->dev);

	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(sd->ctrl_handler);
}

static int hm1092_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct hm1092 *hm1092;
	unsigned long freq;
	int i, ret;

	hm1092 = devm_kzalloc(dev, sizeof(*hm1092), GFP_KERNEL);
	if (!hm1092)
		return -ENOMEM;

	hm1092->dev = dev;
	INIT_DELAYED_WORK(&hm1092->ir_cleanup_work, hm1092_ir_cleanup_worker);

	hm1092->xvclk = devm_v4l2_sensor_clk_get(dev, "xvclk");
	if (IS_ERR(hm1092->xvclk))
		return dev_err_probe(dev, PTR_ERR(hm1092->xvclk),
				     "failed to get xvclk\n");

	freq = clk_get_rate(hm1092->xvclk);
	if (freq != HM1092_XVCLK)
		return dev_err_probe(dev, -EINVAL,
				     "external clock %lu is not supported\n",
				     freq);

	v4l2_i2c_subdev_init(&hm1092->sd, client, &hm1092_subdev_ops);

	/* GPIO_ACTIVE_LOW no DT: OUT_HIGH deixa o sensor em reset. */
	hm1092->reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(hm1092->reset))
		return dev_err_probe(dev, PTR_ERR(hm1092->reset),
				     "failed to get reset gpio\n");

	hm1092->ir_led = devm_of_led_get(dev, 0);
	if (IS_ERR(hm1092->ir_led))
		return dev_err_probe(dev, PTR_ERR(hm1092->ir_led),
				     "failed to get IR illuminator\n");
	if (!hm1092->ir_led->dev || !hm1092->ir_led->dev->parent ||
	    !hm1092->ir_led->dev->parent->parent)
		return dev_err_probe(dev, -ENODEV,
				     "IR illuminator provider is incomplete\n");
	hm1092->ir_provider_regmap =
		dev_get_regmap(hm1092->ir_led->dev->parent->parent, NULL);
	if (!hm1092->ir_provider_regmap)
		return dev_err_probe(dev, -ENODEV,
				     "failed to get IR provider regmap\n");
	ret = device_property_read_u32(hm1092->ir_led->dev->parent,
				       "reg", &hm1092->ir_provider_base);
	if (ret || hm1092->ir_provider_base != HM1092_FLASH_BASE)
		return dev_err_probe(dev, ret ?: -EINVAL,
				     "unexpected IR provider base %#x\n",
				     hm1092->ir_provider_base);

	for (i = 0; i < ARRAY_SIZE(hm1092_supply_names); i++)
		hm1092->supplies[i].supply = hm1092_supply_names[i];

	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(hm1092_supply_names),
				      hm1092->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get supplies\n");

	hm1092->regmap = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(hm1092->regmap))
		return PTR_ERR(hm1092->regmap);

	ret = hm1092_power_on(dev);
	if (ret)
		return dev_err_probe(dev, ret, "failed to power on\n");

	ret = hm1092_identify_module(hm1092);
	if (ret)
		goto probe_error_power_off;

	ret = hm1092_init_controls(hm1092);
	if (ret)
		goto probe_error_v4l2_ctrl_handler_free;

	hm1092->sd.internal_ops = &hm1092_internal_ops;
	hm1092->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	hm1092->sd.entity.ops = &hm1092_subdev_entity_ops;
	hm1092->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	hm1092->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&hm1092->sd.entity, 1, &hm1092->pad);
	if (ret)
		goto probe_error_v4l2_ctrl_handler_free;

	hm1092->sd.state_lock = hm1092->ctrl_handler.lock;
	ret = v4l2_subdev_init_finalize(&hm1092->sd);
	if (ret < 0)
		goto probe_error_media_entity_cleanup;

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);

	ret = v4l2_async_register_subdev_sensor(&hm1092->sd);
	if (ret < 0)
		goto probe_error_v4l2_subdev_cleanup;

	pm_runtime_idle(dev);
	return 0;

probe_error_v4l2_subdev_cleanup:
	pm_runtime_disable(dev);
	pm_runtime_set_suspended(dev);
	v4l2_subdev_cleanup(&hm1092->sd);

probe_error_media_entity_cleanup:
	media_entity_cleanup(&hm1092->sd.entity);

probe_error_v4l2_ctrl_handler_free:
	v4l2_ctrl_handler_free(hm1092->sd.ctrl_handler);

probe_error_power_off:
	hm1092_power_off(dev);
	return ret;
}

static int hm1092_system_suspend(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm1092 = to_hm1092(sd);
	int ret;

	mutex_lock(hm1092->sd.state_lock);
	ret = hm1092_force_ir_off(hm1092, "system suspend");
	mutex_unlock(hm1092->sd.state_lock);
	if (ret)
		return ret;

	return pm_runtime_force_suspend(dev);
}

static int hm1092_system_resume(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct hm1092 *hm1092 = to_hm1092(sd);
	bool sensor_active;
	int ret;

	ret = pm_runtime_force_resume(dev);
	if (ret)
		return ret;

	mutex_lock(hm1092->sd.state_lock);
	if (!hm1092->streaming || hm1092->cleanup_pending) {
		ret = 0;
		goto unlock;
	}

	ret = hm1092_start_streaming_hw(hm1092, &sensor_active);
	if (ret)
		hm1092_schedule_ir_cleanup(hm1092, sensor_active, false, true);

unlock:
	mutex_unlock(hm1092->sd.state_lock);

	return ret;
}

static void hm1092_shutdown(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct hm1092 *hm1092 = to_hm1092(sd);
	int ret;

	mutex_lock(hm1092->sd.state_lock);
	hm1092->removing = true;
	mutex_unlock(hm1092->sd.state_lock);
	cancel_delayed_work_sync(&hm1092->ir_cleanup_work);
	mutex_lock(hm1092->sd.state_lock);
	ret = hm1092_teardown_ir_off(hm1092, "shutdown");
	if (!ret)
		hm1092->streaming = false;
	mutex_unlock(hm1092->sd.state_lock);
}

static const struct dev_pm_ops hm1092_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(hm1092_system_suspend, hm1092_system_resume)
	SET_RUNTIME_PM_OPS(hm1092_power_off, hm1092_power_on, NULL)
};

static const struct of_device_id hm1092_of_match[] = {
	{ .compatible = "himax,hm1092" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, hm1092_of_match);

static struct i2c_driver hm1092_i2c_driver = {
	.driver = {
		.name = "hm1092",
		.pm = pm_ptr(&hm1092_pm_ops),
		.of_match_table = hm1092_of_match,
	},
	.probe = hm1092_probe,
	.remove = hm1092_remove,
	.shutdown = hm1092_shutdown,
};

module_i2c_driver(hm1092_i2c_driver);

MODULE_AUTHOR("Pir0c0pter0");
MODULE_DESCRIPTION("Himax HM1092 IR sensor driver");
MODULE_LICENSE("GPL");
MODULE_SOFTDEP("pre: leds_qcom_flash");
