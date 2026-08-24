# qnn_soc_id_fix - shim LD_PRELOAD do SoC ID para o QNN
# Padrao do projeto: libs de userspace vao em /usr/local/lib64/

LIBDIR ?= /usr/local/lib64
TARGET  = qnn_soc_id_fix.so
CFLAGS ?= -O2 -Wall -Wextra -fPIC

all: $(TARGET)

$(TARGET): qnn_soc_id_fix.c
	$(CC) $(CFLAGS) -shared -o $@ $< -ldl

install: $(TARGET)
	install -D -m 0755 $(TARGET) $(DESTDIR)$(LIBDIR)/$(TARGET)

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/$(TARGET)

# Self-check: usa QNN_SOC_ID_PATH para nao depender do sysfs real.
check: $(TARGET)
	@echo 635 > /tmp/qnn_soc_id_check
	@test "$$(QNN_SOC_ID_PATH=/tmp/qnn_soc_id_check LD_PRELOAD=./$(TARGET) cat /tmp/qnn_soc_id_check)" = 555
	@test "$$(LD_PRELOAD=./$(TARGET) cat /tmp/qnn_soc_id_check)" = 635
	@printf '#include <fcntl.h>\n#include <errno.h>\nint main(void){return open((char*)0,O_RDONLY)==-1&&errno==EFAULT?0:1;}\n' \
	    > /tmp/qnn_null_open.c && $(CC) -o /tmp/qnn_null_open /tmp/qnn_null_open.c
	@LD_PRELOAD=./$(TARGET) /tmp/qnn_null_open   # open(NULL) = EFAULT, nao segfault
	@rm -f /tmp/qnn_soc_id_check /tmp/qnn_null_open /tmp/qnn_null_open.c
	@echo "check OK: redireciona o alvo, deixa o resto passar, open(NULL) intacto"

clean:
	rm -f $(TARGET)

.PHONY: all install uninstall check clean
