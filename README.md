# Arch CPU Performance Setup

This folder contains `arch_cpu_performance_setup.sh`, a small Arch-family helper script for keeping Intel turbo enabled while using `power-profiles-daemon` as the active power manager.

It is meant for Arch, CachyOS, EndeavourOS, Manjaro, and Garuda.

## What The Script Does

- Disables `auto-cpufreq.service` permanently if it exists.
- Enables `power-profiles-daemon.service` permanently.
- Sets the current power profile to `performance`.
- Turns Intel turbo on for the current boot.
- Does not create fallback services or unrelated power-management changes.

## Simple Usage

These setup and verify commands work from Bash, Zsh, and Fish because the script uses its own Bash shebang.

Go to the script folder and run the setup once:

```sh
cd /home/puneeth/Desktop/system
sudo ./arch_cpu_performance_setup.sh
```

Then reboot:

```sh
reboot
```

After reboot, verify:

```sh
cd /home/puneeth/Desktop/system
./arch_cpu_performance_setup.sh --verify-only
```

If the output shows this, you are done:

```text
intel_pstate/no_turbo         0
CPU max MHz                   4800.0000
```

## Quick Rule

Use this flow:

```sh
cd /home/puneeth/Desktop/system
sudo ./arch_cpu_performance_setup.sh
reboot
./arch_cpu_performance_setup.sh --verify-only
```

If `intel_pstate/no_turbo` is `0`, stop. If it is `1`, inspect which service or firmware setting turned turbo off before adding any workaround.

## Load Test With btop

To confirm boost behavior visually, open `btop` in one terminal and watch CPU clocks.

In another terminal, run a single-core load.

Bash/Zsh:

```bash
yes > /dev/null &
LOAD_PID=$!
```

Fish:

```fish
yes > /dev/null &
set LOAD_PID $last_pid
```

You should see at least one performance core boost well above base clock, often near `4.8 GHz` for short bursts when plugged in.

Stop the load.

Bash/Zsh:

```bash
kill "$LOAD_PID"
```

Fish:

```fish
kill $LOAD_PID
```

For a stronger all-core check, run:

Bash/Zsh:

```bash
for i in $(seq 1 "$(nproc)"); do yes > /dev/null & done
```

Fish:

```fish
for i in (seq 1 (nproc))
    yes > /dev/null &
end
```

Stop all `yes` load processes:

```sh
killall yes
```

During all-core load, do not expect every core to stay at `4.8 GHz`. That number is the max turbo ceiling. Sustained all-core clocks will usually be lower depending on temperature and power limits.

# Display Refresh Power Setup

This folder also contains `display_refresh_power_setup.sh`, a user-session helper for switching the internal laptop display refresh rate based on charger state.

It uses:

- `120 Hz` when plugged in
- `60 Hz` on battery

It targets the internal panel automatically. On this laptop, that is `eDP-1`, with:

- `2880x1800@60`
- `2880x1800@120`

Requirements:

- `kscreen-doctor`
- `jq`
- `systemd --user`

## Important

Do not run this one with `sudo`. Display refresh changes belong to your logged-in desktop session.

These commands work from Bash, Zsh, and Fish because the script uses its own Bash shebang.

## Install The Auto Switcher

```sh
cd /home/puneeth/Desktop/system
./display_refresh_power_setup.sh
```

This installs and starts a user systemd service:

```text
display-refresh-power.service
```

The service checks power state every few seconds and only changes refresh rate when AC/battery state changes.

## Check Status

```sh
cd /home/puneeth/Desktop/system
./display_refresh_power_setup.sh --status
```

Expected while plugged in:

```text
power state                  ac
target refresh               120 Hz
```

Expected on battery:

```text
power state                  battery
target refresh               60 Hz
```

## Apply Once

To switch once without installing the background service:

```sh
cd /home/puneeth/Desktop/system
./display_refresh_power_setup.sh --apply
```

## Uninstall

```sh
cd /home/puneeth/Desktop/system
./display_refresh_power_setup.sh --uninstall
```
