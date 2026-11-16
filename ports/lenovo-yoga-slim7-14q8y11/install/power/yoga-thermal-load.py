#!/usr/bin/python3
"""Carga de CPU com monitor termico e aborto. So le /sys; nao escreve nada.

uso: yoga-thermal-load.py [segundos=180] [aborto_mC=95000] [processos=nproc]
     yoga-thermal-load.py 0      # so uma leitura (auto-teste)
Saida CSV: t,fase,Tmax_mC,zona,freq_kHz,cdev_cpufreq,fan_rpm,ec_max_mC
Sai com 2 se abortou por temperatura.
"""
import glob, multiprocessing as mp, os, sys, time


def rd(p, d=None):
    try:
        return open(p).read().strip()
    except OSError:
        return d


def sample():
    tmax, zone = -1, "?"
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        t = rd(z + "/temp")
        if t and t.lstrip("-").isdigit() and int(t) > tmax:
            tmax, zone = int(t), rd(z + "/type", "?")
    freq = rd("/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq", "-")
    cdev = "-"
    for c in glob.glob("/sys/class/thermal/cooling_device*"):
        if rd(c + "/type", "").startswith("cpufreq"):
            cdev = rd(c + "/cur_state", "-")
    fan, ec = "-", "-"
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        if rd(h + "/name") == "yoga_slim7x_ec":
            fan = rd(h + "/fan1_input", "-")
            ec = max([int(rd(f, "0")) for f in glob.glob(h + "/temp*_input")] or [0])
    return tmax, zone, freq, cdev, fan, ec


def burn():
    while True:
        pass


def main():
    dur = int(sys.argv[1]) if len(sys.argv) > 1 else 180
    abort = int(sys.argv[2]) if len(sys.argv) > 2 else 95000
    n = int(sys.argv[3]) if len(sys.argv) > 3 else os.cpu_count()
    assert sample()[0] > 0, "nenhuma thermal zone legivel"
    print("t,fase,Tmax_mC,zona,freq_kHz,cdev_cpufreq,fan_rpm,ec_max_mC", flush=True)
    procs, rc, t0 = [], 0, time.time()

    def log(fase):
        s = sample()
        print("%d,%s,%s" % (time.time() - t0, fase, ",".join(map(str, s))), flush=True)
        return s[0]

    log("repouso")
    try:
        # rampa: 2 processos por 30 s, depois todos
        for k in range(n if dur else 0):
            if k == 2:
                while time.time() - t0 < min(30, dur):
                    if log("rampa") >= abort:
                        raise OverflowError
                    time.sleep(2)
            p = mp.Process(target=burn, daemon=True)
            p.start()
            procs.append(p)
        while time.time() - t0 < dur:
            if log("carga") >= abort:
                raise OverflowError
            time.sleep(2)
    except OverflowError:
        print("# ABORTO: Tmax >= %d mC" % abort, flush=True)
        rc = 2
    except KeyboardInterrupt:
        rc = 130
    finally:
        for p in procs:
            p.kill()
    for _ in range(30 if dur else 0):  # 60 s de resfriamento
        time.sleep(2)
        log("resfria")
    return rc


if __name__ == "__main__":
    sys.exit(main())
