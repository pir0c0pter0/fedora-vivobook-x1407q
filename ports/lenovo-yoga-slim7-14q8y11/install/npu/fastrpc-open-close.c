// Executar em processos separados para testar reabertura sem QNN/override de SoC.
#include <stdio.h>
#include "remote.h"
int main(void) {
  struct remote_rpc_control_unsigned_module cfg = { .domain = 3, .enable = 1 };
  remote_handle64 handle = 0;
  int rc = remote_session_control(DSPRPC_CONTROL_UNSIGNED_MODULE, &cfg, sizeof(cfg));
  printf("unsigned=%#x\n", (unsigned)rc); fflush(stdout);
  if (rc) return 1;
  rc = remote_handle64_open("file:///libsysmonquery_skel.so?sysmonquery_skel_handle_invoke&_modver=1.0&_dom=cdsp", &handle);
  printf("open=%#x\n", (unsigned)rc); fflush(stdout);
  if (rc) return 1;
  rc = remote_handle64_close(handle);
  printf("close=%#x\n", (unsigned)rc); fflush(stdout);
  return rc ? 1 : 0;
}
