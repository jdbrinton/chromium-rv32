#!/usr/bin/env bash
#
# Boot the RV32 guest under qemu-system-riscv32 with the chromium-rootfs.ext4
# image attached as a virtio-blk device. Inside the guest:
#   * /etc/init.d/S97-mount-chromium-rootfs mounts the ext4 read-only at
#     /usr/local/chromium.
#   * /etc/init.d/S98-run-content-shell-m5 invokes content_shell on either
#     an inline-JS data: URL (M5) or the host Svelte demo (M6).
#   * /etc/init.d/S99-run-d8 runs the M2 d8 acceptance.
#
# Exits 0 if 'M5 PASS' (or 'M6 PASS' when --svelte-host is supplied)
# appears in the boot log within the timeout; non-zero otherwise.
#
# Modes:
#   scripts/run-guest.sh                       # auto: capture log, exit
#   scripts/run-guest.sh --interactive         # ^A x to quit
#   scripts/run-guest.sh --no-autorun          # interactive; skip S98/S99
#
#   scripts/run-guest.sh --svelte-host URL
#       Pass m5-svelte-host=URL on the kernel command-line. The M6 leg
#       runs content_shell against URL and emits 'M6 PASS'/'M6 FAIL'.
#
#   scripts/run-guest.sh --svelte-host URL --screenshot DEST_DIR
#       Spawn tools/capture-screenshot.py alongside qemu; once the page
#       prints 'm6:all-green' the helper calls Page.captureScreenshot
#       and writes DEST_DIR/m6-screenshot-<ts>.png.
#
#   scripts/run-guest.sh --svelte-host URL --gui [--rfb-port N]
#                                                [--rfb-host ADDR]
#       M7 interactive mode. Spawns tools/cdp-vnc-bridge.py; connect a
#       VNC client to <rfb-host>:<rfb-port> (defaults 127.0.0.1:5901)
#       and interact with the rendered Svelte demo. Bridge advertises
#       RFB security type None, so --rfb-host 0.0.0.0 trusts the LAN.
#
#   scripts/run-guest.sh --svelte-host URL --gui-capture DEST_DIR \
#                                          [--gui-click X Y] \
#                                          [--rfb-port N]
#       Spawn the bridge AND tools/rfb-capture.py. Captures a frame
#       (and optionally a post-click frame) for M7 regression check.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/env.sh"

# Early --help dispatch so users can read the modes without first
# satisfying every build prereq.
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '3,42p' "$0"; exit 0 ;;
    esac
done

GUEST_OUT="${PROJECT_ROOT}/toolchain/buildroot-guest"
IMAGES="${GUEST_OUT}/images"
QEMU="${GUEST_OUT}/host/bin/qemu-system-riscv32"
EXT4="${BUILD_DIR}/chromium-rootfs.ext4"

for f in fw_jump.bin Image rootfs.cpio.gz; do
    [ -f "${IMAGES}/${f}" ] || {
        echo "missing ${IMAGES}/${f}; run scripts/build-guest.sh first" >&2
        exit 1
    }
done
[ -x "${QEMU}" ] || { echo "missing ${QEMU} (run scripts/build-guest.sh)"; exit 1; }
[ -f "${EXT4}" ] || {
    echo "missing ${EXT4}; run scripts/install-content-shell-in-rootfs.sh first" >&2
    exit 1
}

mode="auto"
extra_append=""
svelte_host=""
boot_timeout=600
screenshot_dir=""
gui_mode=""
gui_capture_dir=""
gui_click=""
rfb_port="5901"
rfb_host="127.0.0.1"

while [ $# -gt 0 ]; do
    case "$1" in
        --interactive) mode="interactive"; shift ;;
        --no-autorun)
            mode="interactive"
            extra_append=" no-autorun-d8 no-autorun-content-shell-m5"
            shift ;;
        --svelte-host)   svelte_host="$2"; shift 2 ;;
        --timeout)       boot_timeout="$2"; shift 2 ;;
        --screenshot)    screenshot_dir="$2"; shift 2 ;;
        --gui)           gui_mode="interactive"; shift ;;
        --gui-capture)   gui_mode="capture"; gui_capture_dir="$2"; shift 2 ;;
        --gui-click)     gui_click="$2 $3"; shift 3 ;;
        --rfb-port)      rfb_port="$2"; shift 2 ;;
        --rfb-host)      rfb_host="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -n "${screenshot_dir}" ] && [ -z "${svelte_host}" ]; then
    echo "--screenshot requires --svelte-host" >&2
    exit 2
fi
if [ -n "${gui_mode}" ] && [ -z "${svelte_host}" ]; then
    echo "--gui / --gui-capture requires --svelte-host" >&2
    exit 2
fi
if [ -n "${gui_mode}" ] && [ "${mode}" = "interactive" ]; then
    echo "--gui / --gui-capture are incompatible with --interactive / --no-autorun" >&2
    exit 2
fi

extra_kernel=""
if [ -n "${svelte_host}" ]; then
    extra_kernel=" m5-svelte-host=${svelte_host}"
fi
# M7 interactive opt-ins. `--gui` tells the in-guest acceptance script
# to hold content_shell open for an hour and skip the post-M6 poweroff
# so the VNC session can stay attached. `--gui-capture` deliberately
# keeps the default 120 s + poweroff path, so it also acts as an M6
# regression check.
if [ "${gui_mode}" = "interactive" ]; then
    extra_kernel="${extra_kernel} m6-svelte-timeout=3600 m6-no-poweroff"
    if [ "${boot_timeout}" = "600" ]; then
        boot_timeout=3700
    fi
fi
APPEND="console=ttyS0,115200 earlycon=sbi rdinit=/sbin/init${extra_append}${extra_kernel}"

# qemu hostfwd: host's 127.0.0.1:9222 -> guest's :9222. The M6 leg of
# the in-guest acceptance script starts content_shell with
# --remote-debugging-port=9222 so the host-side CDP helpers can reach
# DevTools. The forward is harmless when no helper is running.
COMMON=(
    -M virt
    -cpu rv32,sv32=on
    -m 2G
    -smp 4
    -bios "${IMAGES}/fw_jump.bin"
    -kernel "${IMAGES}/Image"
    -initrd "${IMAGES}/rootfs.cpio.gz"
    -append "${APPEND}"
    -drive "file=${EXT4},if=none,format=raw,id=chromium,readonly=on"
    -device "virtio-blk-device,drive=chromium"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:9222-:9222"
    -device virtio-net-device,netdev=net0
    -no-reboot
)

case "${mode}" in
interactive)
    echo ">>> interactive boot (^A x to quit)"
    exec "${QEMU}" "${COMMON[@]}" -nographic
    ;;
auto)
    LOGS="${PROJECT_ROOT}/logs/run-guest"
    mkdir -p "${LOGS}"
    ts=$(date +%Y%m%d-%H%M%S)
    LOG="${LOGS}/boot-${ts}.log"
    echo ">>> auto boot; log: ${LOG}"
    echo ">>> qemu cmd: ${QEMU} ${COMMON[*]} -nographic"

    # Optional: host-side CDP screenshot capture helper.
    screenshot_pid=""
    screenshot_log=""
    screenshot_out=""
    if [ -n "${screenshot_dir}" ]; then
        mkdir -p "${screenshot_dir}"
        screenshot_out="${screenshot_dir}/m6-screenshot-${ts}.png"
        screenshot_log="${screenshot_dir}/m6-screenshot-${ts}.capture.log"
        capture_script="${PROJECT_ROOT}/tools/capture-screenshot.py"
        echo ">>> screenshot capture helper -> ${screenshot_out}"
        python3 -u "${capture_script}" \
            --output "${screenshot_out}" \
            --cdp-host 127.0.0.1 \
            --cdp-port 9222 \
            --connect-timeout 240 \
            --allgreen-timeout 240 \
            >"${screenshot_log}" 2>&1 &
        screenshot_pid=$!
    fi

    # M7 GUI bridge.
    bridge_pid=""
    bridge_log=""
    capture_harness_pid=""
    gui_capture_out=""
    gui_capture_after=""
    gui_capture_log=""
    if [ -n "${gui_mode}" ]; then
        bridge_log="${LOGS}/bridge-${ts}.log"
        bridge_script="${PROJECT_ROOT}/tools/cdp-vnc-bridge.py"
        echo ">>> M7 CDP->RFB bridge -> ${rfb_host}:${rfb_port}"
        echo ">>> bridge log: ${bridge_log}"
        python3 -u "${bridge_script}" \
            --cdp-host 127.0.0.1 \
            --cdp-port 9222 \
            --rfb-host "${rfb_host}" \
            --rfb-port "${rfb_port}" \
            --connect-timeout 240 \
            >"${bridge_log}" 2>&1 &
        bridge_pid=$!

        case "${gui_mode}" in
        interactive)
            echo ">>> M7 interactive mode: connect a VNC client to ${rfb_host}:${rfb_port}"
            echo "    TigerVNC: vncviewer ${rfb_host}:${rfb_port}"
            if [ "${rfb_host}" = "0.0.0.0" ]; then
                wsl_ip=$(ip -4 -o addr show eth0 2>/dev/null \
                    | awk '{print $4}' | cut -d/ -f1)
                echo "    Windows VNC client (WSL loopback): 127.0.0.1:${rfb_port}"
                if [ -n "${wsl_ip}" ]; then
                    echo "    Windows VNC client (WSL eth0):     ${wsl_ip}:${rfb_port}"
                fi
                echo "    NOTE: RFB security type None -- 0.0.0.0 trusts the LAN."
            else
                echo "    (loopback-only; pass --rfb-host 0.0.0.0 to expose on all NICs)"
            fi
            echo ">>> qemu is running headless on stdout-only; ^C this"
            echo "    script to stop everything."
            ;;
        capture)
            mkdir -p "${gui_capture_dir}"
            gui_capture_out="${gui_capture_dir}/m7-interactive-${ts}.png"
            gui_capture_after="${gui_capture_dir}/m7-interactive-${ts}-after-click.png"
            gui_capture_log="${gui_capture_dir}/m7-interactive-${ts}.capture.log"
            harness_script="${PROJECT_ROOT}/tools/rfb-capture.py"
            click_args=""
            if [ -n "${gui_click}" ]; then
                click_args="--click ${gui_click} --output-after ${gui_capture_after}"
            fi
            echo ">>> M7 capture mode: harness will write ${gui_capture_out}"
            (
                # Wait for both the bridge socket and the m6:all-green
                # sentinel in the boot log before capturing. (The
                # in-guest preamble references the bare string
                # m6:all-green; we must anchor on the quoted console
                # form to avoid capturing too early.)
                for _ in $(seq 1 300); do
                    if grep -q '"m6:all-green"' "${LOG}" 2>/dev/null && \
                       { exec 3<>/dev/tcp/127.0.0.1/${rfb_port}; } 2>/dev/null; then
                        exec 3<&- 3>&- || true
                        break
                    fi
                    sleep 1
                done
                sleep 8
                # shellcheck disable=SC2086
                python3 -u "${harness_script}" \
                    --host 127.0.0.1 --port "${rfb_port}" \
                    --output "${gui_capture_out}" \
                    ${click_args} \
                    --settle 3 \
                    --connect-timeout 120 \
                    >"${gui_capture_log}" 2>&1
            ) &
            capture_harness_pid=$!
            ;;
        esac
    fi

    # `timeout --foreground` disables coreutils' default `setpgid(0,0)`,
    # which would otherwise put qemu in a brand-new process group. When
    # the script runs in an interactive terminal that pgid is a
    # *background* group on the script's controlling TTY, and qemu's
    # `tcsetattr` on stdio (via `-nographic`'s mux device) trips
    # SIGTTOU. The default disposition of SIGTTOU stops the process,
    # which manifests as "guest never boots / 0% CPU". `--foreground`
    # keeps qemu in the script's pgid (the TTY's foreground) so
    # tcsetattr is allowed.
    set +e
    timeout --foreground "${boot_timeout}" "${QEMU}" "${COMMON[@]}" -nographic > "${LOG}" 2>&1
    qemu_rc=$?
    set -e

    if [ -n "${bridge_pid:-}" ]; then
        if kill -0 "${bridge_pid}" 2>/dev/null; then
            kill "${bridge_pid}" 2>/dev/null || true
            sleep 1
            kill -9 "${bridge_pid}" 2>/dev/null || true
        fi
        wait "${bridge_pid}" 2>/dev/null || true
    fi
    if [ -n "${capture_harness_pid:-}" ]; then
        wait "${capture_harness_pid}" 2>/dev/null || true
    fi

    screenshot_rc=""
    if [ -n "${screenshot_pid}" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "${screenshot_pid}" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "${screenshot_pid}" 2>/dev/null; then
            kill "${screenshot_pid}" 2>/dev/null || true
            sleep 1
            kill -9 "${screenshot_pid}" 2>/dev/null || true
        fi
        wait "${screenshot_pid}" 2>/dev/null
        screenshot_rc=$?
    fi

    m5_pass=0; m5_fail=0; m6_pass=0; m6_fail=0
    grep -q 'M5 PASS' "${LOG}" && m5_pass=1
    grep -q 'M5 FAIL' "${LOG}" && m5_fail=1
    grep -q 'M6 PASS' "${LOG}" && m6_pass=1
    grep -q 'M6 FAIL' "${LOG}" && m6_fail=1

    if [ -n "${svelte_host}" ]; then
        if [ "${m6_pass}" = "1" ]; then
            echo ">>> result: M6 PASS (M5=${m5_pass}, M6=1)"
            rc=0
        elif [ "${m6_fail}" = "1" ]; then
            echo ">>> result: M6 FAIL (M5=${m5_pass}, M6=fail-banner; qemu rc=${qemu_rc})"
            rc=1
        else
            echo ">>> result: UNKNOWN (M5=${m5_pass}, M6=no-marker; qemu rc=${qemu_rc})"
            rc=2
        fi
    else
        if [ "${m5_pass}" = "1" ]; then
            echo ">>> result: M5 PASS"
            rc=0
        elif [ "${m5_fail}" = "1" ]; then
            echo ">>> result: M5 FAIL"
            rc=1
        else
            echo ">>> result: UNKNOWN (no PASS/FAIL marker; qemu rc=${qemu_rc})"
            rc=2
        fi
    fi

    echo
    echo ">>> last 60 lines of boot log:"
    tail -n 60 "${LOG}"
    echo
    echo ">>> log saved: ${LOG}"
    if [ -n "${screenshot_pid}" ]; then
        echo ">>> screenshot helper rc: ${screenshot_rc}"
        if [ -f "${screenshot_out}" ] && [ -s "${screenshot_out}" ]; then
            png_size=$(stat -c%s "${screenshot_out}")
            echo ">>> screenshot saved: ${screenshot_out} (${png_size} bytes)"
        else
            echo ">>> screenshot NOT saved; see ${screenshot_log}"
        fi
    fi
    if [ -n "${bridge_pid:-}" ]; then
        echo ">>> M7 bridge log: ${bridge_log}"
    fi
    if [ -n "${capture_harness_pid:-}" ]; then
        if [ -f "${gui_capture_out}" ] && [ -s "${gui_capture_out}" ]; then
            png_size=$(stat -c%s "${gui_capture_out}")
            echo ">>> M7 GUI capture saved: ${gui_capture_out} (${png_size} bytes)"
        else
            echo ">>> M7 GUI capture NOT saved; see ${gui_capture_log:-(none)}"
        fi
        if [ -n "${gui_click}" ] && [ -f "${gui_capture_after}" ] && [ -s "${gui_capture_after}" ]; then
            png_size=$(stat -c%s "${gui_capture_after}")
            echo ">>> M7 GUI capture-after-click saved: ${gui_capture_after} (${png_size} bytes)"
        fi
    fi
    exit "${rc}"
    ;;
esac
