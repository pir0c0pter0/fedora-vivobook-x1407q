/* SPDX-License-Identifier: GPL-2.0 */
#ifndef HM1092_IR_SEQUENCE_H
#define HM1092_IR_SEQUENCE_H

/* Keep the illuminator strictly inside the sensor streaming lifetime. */
struct hm1092_ir_ops {
	int (*sensor_set)(void *context, bool on);
	int (*illuminator_set)(void *context, bool on);
	int (*provider_force_off)(void *context);
	int (*sensor_power_off)(void *context);
	int (*sensor_power_restore)(void *context);
};

#define HM1092_IR_OFF_ATTEMPTS 3

static inline int hm1092_ir_force_off(const struct hm1092_ir_ops *ops,
				       void *context)
{
	int attempt, ret = 0;

	for (attempt = 0; attempt < HM1092_IR_OFF_ATTEMPTS; attempt++) {
		ret = ops->illuminator_set(context, false);
		if (!ret)
			break;
	}

	return ret;
}

static inline int hm1092_ir_teardown_off(const struct hm1092_ir_ops *ops,
					  void *context)
{
	int ret;

	ret = hm1092_ir_force_off(ops, context);
	if (!ret || !ops->provider_force_off)
		return ret;

	return ops->provider_force_off(context);
}

static inline int hm1092_ir_power_off(const struct hm1092_ir_ops *ops,
				       void *context)
{
	int restore_ret, ret;

	ret = hm1092_ir_teardown_off(ops, context);
	if (ret)
		return ret;

	ret = ops->sensor_power_off(context);
	if (!ret || !ops->sensor_power_restore)
		return ret;

	restore_ret = ops->sensor_power_restore(context);
	return restore_ret ?: ret;
}

static inline int hm1092_ir_start(const struct hm1092_ir_ops *ops,
				  void *context, bool *sensor_active)
{
	int ir_off_ret, ret, sensor_off_ret;

	*sensor_active = false;

	ret = ops->sensor_set(context, true);
	if (ret)
		return ret;
	*sensor_active = true;

	ret = ops->illuminator_set(context, true);
	if (ret) {
		/* A failed enable may have programmed part of the PMIC sequence. */
		ir_off_ret = hm1092_ir_force_off(ops, context);
		if (ir_off_ret)
			return ir_off_ret;

		sensor_off_ret = ops->sensor_set(context, false);
		if (sensor_off_ret)
			return sensor_off_ret;
		*sensor_active = false;
	}

	return ret;
}

static inline int hm1092_ir_stop(const struct hm1092_ir_ops *ops,
				 void *context)
{
	int ir_ret, sensor_ret;

	/* Eye-safety invariant: extinguish IR before stopping the sensor. */
	ir_ret = hm1092_ir_force_off(ops, context);
	if (ir_ret)
		return ir_ret;

	sensor_ret = ops->sensor_set(context, false);
	return sensor_ret;
}

#endif
