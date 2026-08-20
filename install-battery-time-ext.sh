#!/bin/bash
# Instala a extensão GNOME Shell "Battery Time Remaining"
# Mostra tempo restante da bateria no painel, ao lado do percentual
# Usa média ponderada do consumo para estimativa mais precisa

set -euo pipefail

EXT_UUID="battery-time@wifiteste"
TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
    echo 'Não foi possível identificar o usuário desktop (SUDO_USER).' >&2
    exit 1
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)
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

# Configure the same user profile that owns the extension.  A non-zero result
# is expected when this script runs before that user's GNOME session exists.
if ! gsettings set org.gnome.desktop.interface show-battery-percentage true; then
    echo 'Percentual da bateria pendente até existir uma sessão GNOME.' >&2
fi
if ! gnome-extensions enable "$EXT_UUID"; then
    echo 'Habilitação da extensão pendente até existir uma sessão GNOME.' >&2
fi

if extension_info=$(gnome-extensions info "$EXT_UUID" 2>&1) &&
    grep -Eq 'State: (ACTIVE|ENABLED)' <<<"$extension_info"; then
    echo "Extensão instalada e habilitada para $TARGET_USER: $EXT_DIR"
    exit 0
fi

echo "Extensão instalada em: $EXT_DIR"
echo "Status: pending-login (habilitação será confirmada após logout/login)"
echo '>>> FAÇA LOGOUT E LOGIN para ativar e confirmar a extensão <<<'
# Do not claim that gnome-extensions enabled the extension until info reports it.
exit 3
