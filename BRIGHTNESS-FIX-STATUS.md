# Brightness Fix Status - ASUS Vivobook X1407QA (Snapdragon X / X1E80100)

## Hardware Summary

| Item | Value |
|------|-------|
| Panel | Innolux N140JCA-ELK (IPS LCD, NOT OLED) |
| PMIC | PMK8550 (SID 0, DT: pmic@0) |
| LPG channel | ch0 at 0xE800 (HI_RES_PWM subtype 0x0C) |
| PWM config | 12-bit (4096 levels), 19.2MHz clock, enabled |
| GPIO for PWM | PMK8550 GPIO5 at 0xBC00 |
| GPIO5 config | mode=0x01 (digital out), DIG_OUT_SOURCE_CTL=0x04, en=0x80 |
| Backlight enable | PMC8380_3 GPIO4 (on/off, already HIGH) |
| DTB PWM nodes | pmk8550_pwm and pm8550_pwm exist but status="disabled" |
| PWM driver | leds-qcom-lpg.ko available but not loaded (nodes disabled) |

## LPG Register Map (base 0xE800)

| Offset | Register | Current Value | Notes |
|--------|----------|---------------|-------|
| 0x05 | PERPH_SUBTYPE | 0x0C | HI_RES_PWM confirmed |
| 0x41 | SIZE_CLK | 0x43 | 19.2MHz, 12-bit |
| 0x42 | PREDIV | 0x01 | div by 2 |
| 0x44 | VALUE_LSB | (variable) | PWM duty cycle low byte |
| 0x45 | VALUE_MSB | (variable) | PWM duty cycle high byte |
| 0x46 | ENABLE | 0x80 | bit 7 = enabled |
| 0x47 | PWM_SYNC | 0x00 | Write 1 to latch value regs (self-clearing) |
| 0xD0 | SEC_ACCESS | - | Write 0xA5 to unlock protected write |
| 0xE0 | TEST1/DTEST1 | 0x00 | DTEST1 output (write-only, reads always 0) |
| 0xE2 | TEST3/DTEST3 | 0x00 | DTEST3 output (writable, readback works) |

## GPIO5 Register Map (base 0xBC00)

| Offset | Register | Value | Meaning |
|--------|----------|-------|---------|
| 0x40 | MODE_CTL | 0x01 | Digital output |
| 0x41 | DIG_VIN_CTL | 0x00 | - |
| 0x42 | DIG_PULL_CTL | 0x04 | - |
| 0x43 | DIG_IN_CTL | 0x00 | - |
| 0x44 | DIG_OUT_SOURCE_CTL | 0x04 | Source select (see mapping below) |
| 0x45 | DIG_OUT_CTL | 0x02 | Output drive config |
| 0x46 | EN_CTL | 0x80 | Enabled |

### LV/MV GPIO DIG_OUT_SOURCE_CTL mapping (bits[3:0])

Based on pinctrl-spmi-gpio.c for LV/MV type GPIOs, the values are offset by func3:
- 0 = func3, 1 = func4, 2 = dtest1, 3 = dtest2, 4 = dtest3, 5 = dtest4

So GPIO5 with value 0x04 = **dtest3** (NOT dtest1 as originally assumed!)

## What Works

- **DTEST routing causes brightness change**: Writing 0x01 to E2 (LPG DTEST3 output) caused ~15-20% dimming that persisted. This confirms:
  - GPIO5 sources DTEST3 (reg value 0x04)
  - LPG can drive DTEST3 via register E2
  - The PWM signal IS reaching the panel's backlight input

## What DOESN'T Work / DANGEROUS

| Approach | Result | NEVER DO |
|----------|--------|----------|
| GPIO5 DIG_OUT_SOURCE_CTL = 0x00 (func3) | **KILLS DISPLAY**, forced reboot | YES |
| GPIO5 force LOW (from previous session) | **KILLS DISPLAY**, forced reboot | YES |
| DPCD/AUX backlight | Panel doesn't support (DPCD 0x701 bit 0 = 0) | - |
| DTB overlay/modification | INSYDE firmware blocks all 7 methods | - |
| WLED | Not present on any PMIC | - |
| ACPI backlight | No _BCM/_BCL methods in DSDT | - |

## Current Problem: PWM Value Changes Have No Visible Effect

The DTEST routing works (proved by 15-20% dimming), but changing the PWM value registers (0x44-0x45) has no visible effect on brightness.

**Root cause hypothesis: Missing PWM_SYNC**

The `leds-qcom-lpg` driver writes `1` to `PWM_SYNC_REG` (offset 0x47) after every PWM value change to latch the new value into the hardware PWM generator. Our module was NOT doing this. Register 0x47 is self-clearing (write 1, reads back 0).

```c
// From leds-qcom-lpg.c:
regmap_write(lpg->map, chan->base + PWM_SYNC_REG, 1);
```

## DKMS Module Files

Located at `/usr/src/vivobook-bl-fix-1.0/`:
- `vivobook_bl_fix.c` - main module source
- `Makefile` - kernel module build
- `dkms.conf` - DKMS packaging config

## Next Steps

1. **Add PWM_SYNC** to `write_pwm_value()` - write 1 to offset 0x47 after updating value regs
2. **Remove DTEST1 (E0) writes** - only E2 (DTEST3) matters since GPIO5 sources DTEST3
3. **Test** brightness control via sysfs
4. If works: configure auto-load, test Fn keys with GNOME
5. If doesn't work: investigate if PWM_SYNC needs SEC_ACCESS, try different DTEST values

## Reference DTS (from HP Omnibook / Microsoft Romulus)

```dts
backlight {
    compatible = "pwm-backlight";
    pwms = <&pmk8550_pwm 0 5000000>;
    enable-gpios = <&pmc8380_3_gpios 4 GPIO_ACTIVE_HIGH>;
};

&pmk8550_gpios {
    edp_bl_pwm: edp-bl-pwm-state {
        pins = "gpio5";
        function = "func3";  /* WARNING: func3=0x00 KILLS display on our hardware! */
    };
};
```

## Key Lessons

1. GPIO DIG_OUT_SOURCE_CTL mapping for LV/MV GPIOs is OFFSET - value 0x04 ≠ DTEST1, it's DTEST3
2. LPG TEST register E0 is write-only (readback always 0x00)
3. LPG TEST register E2 is read-write (readback confirms writes)
4. PWM_SYNC (0x47) is required to latch PWM value changes into hardware
5. NEVER change GPIO5 output source or force output values - can kill display
6. DTEST approach works - just needs proper value syncing
