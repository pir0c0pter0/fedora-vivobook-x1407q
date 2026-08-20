#!/bin/bash
# Instala a extensão GNOME Shell "Battery Time Remaining"
# Mostra tempo restante da bateria no painel, ao lado do percentual
# Usa média ponderada do consumo para estimativa mais precisa

set -euo pipefail

EXT_UUID="battery-time@wifiteste"
MODE=install
REQUESTED_USER=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --activate-only) MODE=activate-only ;;
        --user)
            shift
            REQUESTED_USER=${1:-}
            ;;
        *)
            echo "Opção desconhecida: $1" >&2
            exit 2
            ;;
    esac
    shift
done

TARGET_USER="${REQUESTED_USER:-${SUDO_USER:-${USER:-}}}"
if [[ -z "$TARGET_USER" ]]; then
    echo 'Não foi possível identificar o usuário desktop (SUDO_USER).' >&2
    exit 1
fi
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || true)
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
if [[ ${BATTERY_TIME_TEST_MODE:-0} == 1 ]]; then
    # Test-only path overrides are inert unless this explicit mode is set.
    TARGET_HOME=${BATTERY_TIME_TEST_HOME:?BATTERY_TIME_TEST_HOME is required in test mode}
fi
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "Home inválida para o usuário desktop: $TARGET_USER" >&2
    exit 1
fi
if [[ $EUID -eq 0 && "$TARGET_USER" != root ]]; then
    exec sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" SUDO_USER="$TARGET_USER" \
        bash "$0" "$@"
fi
if [[ $(id -un) != "$TARGET_USER" ]]; then
    echo "A extensão deve ser instalada como $TARGET_USER, não como $(id -un)." >&2
    exit 1
fi
EXT_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
STATE_DIR="$TARGET_HOME/.local/state/battery-time-extension"
STATUS_FILE="$STATE_DIR/status"
AUTOSTART_DIR="$TARGET_HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/battery-time-extension-activation.desktop"
TARGET_RUNTIME_DIR="/run/user/${TARGET_UID}"
if [[ ${BATTERY_TIME_TEST_MODE:-0} == 1 ]]; then
    TARGET_RUNTIME_DIR=${BATTERY_TIME_TEST_RUNTIME_DIR:?BATTERY_TIME_TEST_RUNTIME_DIR is required in test mode}
fi
SESSION_BUS="$TARGET_RUNTIME_DIR/bus"
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")

write_status() {
    local state=$1 status_tmp

    mkdir -p "$STATE_DIR" || return 1
    status_tmp="${STATUS_FILE}.new.$$"
    printf '%s\n' "$state" > "$status_tmp" || return 1
    mv -Tf -- "$status_tmp" "$STATUS_FILE"
}

install_pending_autostart() {
    mkdir -p "$AUTOSTART_DIR" || return 1
    cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Battery Time Extension Activation
Exec=${SCRIPT_PATH} --activate-only --user ${TARGET_USER}
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
}

session_bus_available() {
    [[ -n "$TARGET_UID" && -d "$TARGET_RUNTIME_DIR" && ! -L "$TARGET_RUNTIME_DIR" &&
        -S "$SESSION_BUS" && ! -L "$SESSION_BUS" ]] || return 3
    [[ $(stat -c %u "$TARGET_RUNTIME_DIR") == "$TARGET_UID" &&
        $(stat -c %u "$SESSION_BUS") == "$TARGET_UID" ]] || return 3
}

gnome_shell_owner_available() {
    local owner_reply

    session_bus_available || return 3
    if command -v gdbus >/dev/null 2>&1; then
        owner_reply=$(XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$SESSION_BUS" \
            gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null) || {
            echo 'Não foi possível consultar o owner org.gnome.Shell no D-Bus; mantendo pending-login.' >&2
            return 3
        }
        [[ $owner_reply == *true* ]] && return 0
    elif command -v busctl >/dev/null 2>&1; then
        owner_reply=$(XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$SESSION_BUS" \
            busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s org.gnome.Shell 2>/dev/null) || {
            echo 'Não foi possível consultar o owner org.gnome.Shell no D-Bus; mantendo pending-login.' >&2
            return 3
        }
        [[ $owner_reply == *true* ]] && return 0
    else
        echo 'gdbus/busctl indisponível; não assumindo uma Shell ativa.' >&2
        return 3
    fi
    echo 'org.gnome.Shell não possui o bus da sessão; mantendo pending-login.' >&2
    return 3
}

verify_and_activate_session() {
    local enable_output extension_info

    # The caller has proved that this is the real user's bus socket.  Export
    # the matching session coordinates for every GNOME command below.
    export XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$SESSION_BUS"
    if ! gsettings set org.gnome.desktop.interface show-battery-percentage true ||
        [[ $(gsettings get org.gnome.desktop.interface show-battery-percentage) != true ]]; then
        write_status fatal || true
        echo 'Falha ao habilitar/verificar o percentual da bateria na sessão GNOME.' >&2
        return 1
    fi
    if ! enable_output=$(gnome-extensions enable "$EXT_UUID" 2>&1); then
        if grep -Eqi 'does not exist|doesn.t exist|não existe' <<<"$enable_output"; then
            write_status pending-login || return 1
            echo 'A Shell atual ainda não descobriu a extensão; mantendo pending-login.' >&2
            return 3
        fi
        write_status fatal || true
        [[ -z $enable_output ]] || echo "$enable_output" >&2
        echo 'Falha ao habilitar a extensão na sessão GNOME.' >&2
        return 1
    fi
    if ! extension_info=$(gnome-extensions info "$EXT_UUID" 2>&1); then
        write_status fatal || true
        echo 'gnome-extensions info falhou na sessão GNOME.' >&2
        return 1
    fi
    if ! grep -Eq 'State: (ACTIVE|ENABLED)' <<<"$extension_info"; then
        write_status fatal || true
        echo 'A extensão não ficou habilitada segundo gnome-extensions info.' >&2
        return 1
    fi
    write_status enabled || return 1
    rm -f -- "$AUTOSTART_FILE" || return 1
    echo "Extensão e percentual verificados na sessão de $TARGET_USER."
}

activate_or_queue() {
    install_pending_autostart || return 1
    if ! gnome_shell_owner_available; then
        write_status pending-login || return 1
        echo 'Status: pending-login; ativação será repetida pelo autostart no próximo login.'
        return 3
    fi
    verify_and_activate_session
}

if [[ "$MODE" == activate-only ]]; then
    activate_or_queue
    exit $?
fi

echo "=== Instalando extensão Battery Time Remaining ==="

mkdir -p "$EXT_DIR"

# metadata.json
cat > "$EXT_DIR/metadata.json" << 'METADATA'
{
  "uuid": "battery-time@wifiteste",
  "name": "Battery Time Remaining",
  "description": "Shows battery time remaining in the panel with improved estimation (rolling average)",
  "shell-version": ["50", "50.rc", "51"],
  "version": 1
}
METADATA

# extension.js
cat > "$EXT_DIR/extension.js" << 'EXTJS'
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import St from 'gi://St';
import UPower from 'gi://UPowerGlib';

import {panel} from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SYSFS_BAT = '/sys/class/power_supply/qcom-battmgr-bat';
const HISTORY_SIZE = 30;
const UPDATE_SEC = 30;

function readSysfsNum(filename) {
    try {
        const path = `${SYSFS_BAT}/${filename}`;
        const [ok, data] = GLib.file_get_contents(path);
        if (ok) {
            const val = parseFloat(new TextDecoder().decode(data).trim());
            return isNaN(val) ? null : val;
        }
    } catch (_) {}
    return null;
}

export default class BatteryTimeExtension extends Extension {
    enable() {
        this._rateHistory = [];
        this._timeLabel = null;
        this._proxySignalId = null;
        this._timerId = null;
        this._desktopSettings = null;
        this._settingsSignalId = null;
        this._hovering = false;
        this._enterSignalId = null;
        this._leaveSignalId = null;

        this._initId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            this._initId = null;
            this._setup();
            return GLib.SOURCE_REMOVE;
        });
    }

    _setup() {
        const qs = panel.statusArea.quickSettings;
        if (!qs?._system) {
            this._initId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._initId = null;
                this._setup();
                return GLib.SOURCE_REMOVE;
            });
            return;
        }

        const system = qs._system;
        const powerToggle = system._systemItem?.powerToggle
            ?? system._systemItem?._powerToggle;

        if (!powerToggle?._proxy)
            return;

        this._proxy = powerToggle._proxy;

        this._timeLabel = new St.Label({
            y_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'power-status',
            style: 'margin-left: 2px; font-size: 0.9em;',
        });
        system.add_child(this._timeLabel);
        this._timeLabel.hide();

        // Show/hide time on hover
        this._system = system;
        system.reactive = true;
        this._enterSignalId = system.connect('enter-event', () => {
            this._hovering = true;
            this._update();
        });
        this._leaveSignalId = system.connect('leave-event', () => {
            this._hovering = false;
            this._timeLabel.hide();
        });

        this._desktopSettings = new Gio.Settings({
            schema_id: 'org.gnome.desktop.interface',
        });
        this._settingsSignalId = this._desktopSettings.connect(
            'changed::show-battery-percentage',
            () => this._update()
        );

        this._proxySignalId = this._proxy.connect(
            'g-properties-changed',
            () => this._update()
        );

        this._sampleRate();
        this._update();

        this._timerId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            UPDATE_SEC,
            () => {
                this._sampleRate();
                this._update();
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    _sampleRate() {
        const power = readSysfsNum('power_now');
        if (power !== null && power > 0) {
            this._rateHistory.push(power / 1_000_000);
            if (this._rateHistory.length > HISTORY_SIZE)
                this._rateHistory.shift();
        }
    }

    _avgRate() {
        if (this._rateHistory.length === 0)
            return null;
        let weightSum = 0;
        let valSum = 0;
        for (let i = 0; i < this._rateHistory.length; i++) {
            const w = 1 + i;
            valSum += this._rateHistory[i] * w;
            weightSum += w;
        }
        return valSum / weightSum;
    }

    _formatTime(totalSeconds) {
        if (totalSeconds <= 0 || !isFinite(totalSeconds))
            return null;
        const h = Math.floor(totalSeconds / 3600);
        const m = Math.floor((totalSeconds % 3600) / 60);
        return `${h}:${String(m).padStart(2, '0')}`;
    }

    _update() {
        if (!this._timeLabel || !this._proxy)
            return;

        const showPct = this._desktopSettings?.get_boolean(
            'show-battery-percentage') ?? true;

        if (!showPct || !this._proxy.IsPresent) {
            this._timeLabel.hide();
            return;
        }

        const state = this._proxy.State;
        let timeStr = null;

        if (state === UPower.DeviceState.DISCHARGING) {
            const avgRate = this._avgRate();
            const energyNow = readSysfsNum('energy_now');
            if (avgRate && avgRate > 0 && energyNow !== null) {
                const energyWh = energyNow / 1_000_000;
                const seconds = (energyWh / avgRate) * 3600;
                timeStr = this._formatTime(seconds);
            } else if (this._proxy.TimeToEmpty > 0) {
                timeStr = this._formatTime(this._proxy.TimeToEmpty);
            }
        } else if (state === UPower.DeviceState.CHARGING) {
            if (this._proxy.TimeToFull > 0)
                timeStr = this._formatTime(this._proxy.TimeToFull);
        }

        if (timeStr) {
            this._timeLabel.set_text(timeStr);
            if (this._hovering)
                this._timeLabel.show();
        } else {
            this._timeLabel.hide();
        }
    }

    disable() {
        if (this._initId) {
            GLib.source_remove(this._initId);
            this._initId = null;
        }

        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = null;
        }

        if (this._proxySignalId && this._proxy) {
            this._proxy.disconnect(this._proxySignalId);
            this._proxySignalId = null;
        }

        if (this._settingsSignalId && this._desktopSettings) {
            this._desktopSettings.disconnect(this._settingsSignalId);
            this._settingsSignalId = null;
        }

        if (this._enterSignalId && this._system) {
            this._system.disconnect(this._enterSignalId);
            this._enterSignalId = null;
        }
        if (this._leaveSignalId && this._system) {
            this._system.disconnect(this._leaveSignalId);
            this._leaveSignalId = null;
        }
        this._system = null;
        this._hovering = false;

        if (this._timeLabel) {
            this._timeLabel.destroy();
            this._timeLabel = null;
        }

        this._proxy = null;
        this._desktopSettings = null;
        this._rateHistory = [];
    }
}
EXTJS

activate_or_queue
exit $?
