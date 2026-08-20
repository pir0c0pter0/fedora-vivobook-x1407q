obj-m += vivobook_hotkey_fix.o

KDIR ?= /lib/modules/$(if $(KERNELRELEASE),$(KERNELRELEASE),$(shell uname -r))/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
