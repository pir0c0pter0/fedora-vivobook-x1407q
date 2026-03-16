obj-m += vivobook_cam_fix.o

KDIR := /lib/modules/$(shell uname -r)/build
DTC  := dtc
CPP  := cpp

OVERLAYS := vivobook_cam_phase1 vivobook_cam_phase2

ifneq ($(KERNELRELEASE),)

$(obj)/vivobook_cam_fix.o: $(addprefix $(obj)/,$(addsuffix .dtbo.h,$(OVERLAYS)))

define OVERLAY_RULES
$(obj)/$(1).dtbo: $(src)/$(1).dts
	$$(CPP) -nostdinc \
		-I$$(KDIR)/include \
		-I$$(KDIR)/include/uapi \
		-undef -x assembler-with-cpp $$< | \
	$$(DTC) -@ -I dts -O dtb -o $$@ -

$(obj)/$(1).dtbo.h: $(obj)/$(1).dtbo
	xxd -i $$< > $$@
	sed -i 's|[a-z_/]*$(1)_dtbo|$(1)_dtbo|g' $$@
endef

$(foreach ov,$(OVERLAYS),$(eval $(call OVERLAY_RULES,$(ov))))

else

define OVERLAY_RULES_STANDALONE
$(1).dtbo: $(1).dts
	$$(CPP) -nostdinc \
		-I$$(KDIR)/include \
		-I$$(KDIR)/include/uapi \
		-undef -x assembler-with-cpp $$< | \
	$$(DTC) -@ -I dts -O dtb -o $$@ -

$(1).dtbo.h: $(1).dtbo
	xxd -i $$< > $$@
	sed -i 's|[a-z_/]*$(1)_dtbo|$(1)_dtbo|g' $$@
endef

$(foreach ov,$(OVERLAYS),$(eval $(call OVERLAY_RULES_STANDALONE,$(ov))))

OVERLAY_HEADERS := $(addsuffix .dtbo.h,$(OVERLAYS))

all: $(OVERLAY_HEADERS)
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f $(addsuffix .dtbo,$(OVERLAYS)) $(addsuffix .dtbo.h,$(OVERLAYS))

endif
