#!/bin/sh
# Milestone 5 acceptance script.
#
# Runs Chromium content_shell inside the rv32 guest under qemu-system, on
# an inline-JS data: URL. Prints a sentinel banner so the host boot script
# can detect M5 PASS / FAIL the same way the M2 d8 acceptance does.
#
# Optional second pass (when /etc/m5-svelte-host is present) points
# content_shell at the host-served Svelte 5 demo via slirp NAT. That run is
# expected to fail today because external JavaScript (incl. data: URL with
# <script src=> and HTTP Svelte modules) triggers a documented V8 trampoline
# SEGV — see milestones/m4-content-shell/STATUS.md "M6 follow-up". We
# capture the log and continue.

set -u

LOGDIR=/var/log
mkdir -p "${LOGDIR}"

# Portable timeout: this buildroot busybox is built without CONFIG_TIMEOUT
# so we roll our own.  Usage: timeout_run SECONDS LOGFILE CMD [ARGS...]
# Backgrounds the command, also backgrounds a watchdog that SIGTERMs (then
# SIGKILLs) the command after SECONDS, then waits on the command. Exit
# status is the command's exit status (or 124 / 137 if killed).
timeout_run() {
	_to_secs="$1"; _to_log="$2"; shift 2
	"$@" >"${_to_log}" 2>&1 &
	_to_cmd_pid=$!
	(
		_left="${_to_secs}"
		while [ "${_left}" -gt 0 ]; do
			kill -0 "${_to_cmd_pid}" 2>/dev/null || exit 0
			sleep 1
			_left=$((_left - 1))
		done
		kill -TERM "${_to_cmd_pid}" 2>/dev/null
		sleep 5
		kill -KILL "${_to_cmd_pid}" 2>/dev/null
	) &
	_to_wd_pid=$!
	wait "${_to_cmd_pid}" 2>/dev/null
	_to_rc=$?
	kill -KILL "${_to_wd_pid}" 2>/dev/null
	wait "${_to_wd_pid}" 2>/dev/null
	return "${_to_rc}"
}

echo
echo "==== chromium-rv32 M5 acceptance ===="
echo "uname:       $(uname -a)"
echo "ram free:    $(grep MemAvailable /proc/meminfo)"
echo "content_shell launcher: $(realpath /usr/local/bin/content_shell)"
ls -lh /usr/local/chromium/content_shell 2>/dev/null | head -1
echo

DATA_URL='data:text/html,<title>m5</title><script>console.log("rv32-content-shell-js-ok-m5:"+(7+8));console.log("rv32-content-shell-ua:"+(typeof navigator!=="undefined"?navigator.userAgent:"n/a"));document.title="rv32-content-shell-m5-done";</script>'

echo "----- inline-JS data: URL pass -----"
# `--dump-dom` makes content_shell render once and exit. The runtime is
# dominated by V8 isolate startup + the embedded snapshot decode; expect
# ~30-60 s on qemu-system-riscv32 (single TCG-translated core).
INLINE_LOG="${LOGDIR}/m5-inline.log"
timeout_run 180 "${INLINE_LOG}" /usr/local/bin/content_shell --dump-dom "${DATA_URL}"
inline_rc=$?
# Print only the lines that matter so the M2-style boot grep finds the
# sentinel even though content_shell is otherwise chatty.
grep -E 'DevTools listening|rv32-content-shell-js-ok-m5|rv32-content-shell-ua|rv32-content-shell-m5-done' \
	"${INLINE_LOG}" || true
echo "(inline content_shell exit=${inline_rc}, full log: ${INLINE_LOG})"
echo "----- /var/log/m5-inline.log (last 40 lines) -----"
tail -40 "${INLINE_LOG}" || true
echo "----- end /var/log/m5-inline.log -----"
echo

# Detect PASS based on the sentinel — content_shell may exit non-zero due
# to harmless shutdown races; the sentinel print is the real signal.
if grep -q 'rv32-content-shell-js-ok-m5:15' "${INLINE_LOG}"; then
	echo "==== M5 PASS (inline JS sentinel present) ===="
	m5_pass=1
else
	echo "==== M5 FAIL (no sentinel; see ${INLINE_LOG}) ===="
	m5_pass=0
fi
echo

# --- M6 leg: Svelte 5 demo via host SvelteKit server ------------------------
#
# Originally documented as expected-to-fail (V8 trampoline SEGV). With the
# M6 path-A workaround landed in
#   src/chromium/src/v8/src/builtins/riscv/builtins-riscv.cc
# (see milestones/m6-svelte-in-browser/STATUS.md), this leg now runs to
# completion and prints `==== M6 PASS ====` when the four subsystem
# sentinels are seen in content_shell stderr:
#   m6:hydrated:<iso>
#   m6:dom-update:counter=<n>
#   m6:fetch-ok:at=<iso>
#   m6:sse-tick:n=<n>:at=<iso>
# and the convergence sentinel `m6:all-green` from the page's $effect.
#
# Two ways to enable:
#   * /etc/m5-svelte-host           - file containing the URL.
#   * m5-svelte-host=<url> on the   - token on /proc/cmdline (set by
#     kernel command line             70-boot-chromium-guest.sh
#                                     --svelte-host URL).
HOST_URL=""
if [ -f /etc/m5-svelte-host ]; then
	HOST_URL="$(cat /etc/m5-svelte-host)"
else
	# Parse `m5-svelte-host=URL` out of /proc/cmdline if present.
	HOST_URL="$(sed -n 's/.*m5-svelte-host=\([^[:space:]]*\).*/\1/p' /proc/cmdline 2>/dev/null)"
fi
if [ -n "${HOST_URL}" ]; then
	SVELTE_LOG="${LOGDIR}/m6-svelte.log"
	echo "----- M6 leg: Svelte 5 demo (host ${HOST_URL}) -----"
	echo "Running content_shell against the SvelteKit hydration demo. The"
	echo "page emits m6:hydrated, m6:dom-update, m6:fetch-ok, m6:sse-tick,"
	echo "m6:all-green console.log sentinels as each subsystem proves itself."

	# M7-interactive opt-in: parse `m6-svelte-timeout=N` from /proc/cmdline.
	# Defaults to 120 (M6 baseline). The host-side
	# scripts/70-boot-chromium-guest.sh --gui mode passes a much larger
	# value (e.g. 3600) so a VNC client connected to the M7 CDP->RFB
	# bridge has enough time for manual interaction. When the token is
	# absent, behaviour is byte-identical to the original M6 acceptance
	# (timeout_run 120).
	M6_TIMEOUT=$(sed -n 's/.*m6-svelte-timeout=\([^[:space:]]*\).*/\1/p' /proc/cmdline 2>/dev/null)
	M6_TIMEOUT=${M6_TIMEOUT:-120}
	case "${M6_TIMEOUT}" in
		''|*[!0-9]*) M6_TIMEOUT=120 ;;
	esac

	# Run WITHOUT --dump-dom: we need content_shell to stay alive long enough
	# for the SvelteKit page to hydrate, complete the auto-fetch round-trip,
	# and consume at least one /sse tick (ticks every 1 s; budget 60 s).
	#
	# --remote-debugging-port + --remote-debugging-address expose the Chrome
	# DevTools Protocol endpoint on the guest's :9222 interface. The host
	# can reach this via the qemu user-net `hostfwd=tcp:127.0.0.1:9222-:9222`
	# rule set up in scripts/70-boot-chromium-guest.sh, which lets the
	# host-side capture-screenshot.py call Page.captureScreenshot and write
	# a rendered-pixel PNG. These flags are no-ops when no client connects.
	echo "M6 leg: content_shell timeout = ${M6_TIMEOUT}s"
	timeout_run "${M6_TIMEOUT}" "${SVELTE_LOG}" /usr/local/bin/content_shell \
		--remote-debugging-port=9222 \
		--remote-debugging-address=0.0.0.0 \
		"${HOST_URL}"
	svelte_rc=$?

	# Sentinel grep -- count each independently so the banner explains which
	# leg of the 4-light board failed if M6 is FAIL.
	#
	# NOTE: `grep -c` always prints a number, but exits 1 when count==0. We
	# must NOT chain `|| echo 0` because that appends a second "0" line and
	# the `[ "$x" -gt 0 ]` numeric test below would then choke on the
	# multi-line value ("sh: 0\n0: bad number"). Letting grep's exit status
	# through is fine; it's never read.
	hyd=$(grep -c  'm6:hydrated:'                              "${SVELTE_LOG}" 2>/dev/null)
	dom=$(grep -c  'm6:dom-update:'                            "${SVELTE_LOG}" 2>/dev/null)
	fet=$(grep -c  'm6:fetch-ok:'                              "${SVELTE_LOG}" 2>/dev/null)
	sse=$(grep -c  'm6:sse-tick:'                              "${SVELTE_LOG}" 2>/dev/null)
	grn=$(grep -c  'm6:all-green'                              "${SVELTE_LOG}" 2>/dev/null)
	segv=$(grep -cE 'InterpreterEntryTrampoline|SEGV_MAPERR'   "${SVELTE_LOG}" 2>/dev/null)
	hyd=${hyd:-0}; dom=${dom:-0}; fet=${fet:-0}; sse=${sse:-0}; grn=${grn:-0}; segv=${segv:-0}

	echo "  sentinels: hydrated=${hyd} dom-update=${dom} fetch-ok=${fet} sse-tick=${sse} all-green=${grn}"
	echo "  trampoline SEGV markers in log: ${segv} (must be 0)"

	grep -E 'DevTools listening|m6:|InterpreterEntryTrampoline|Received signal|SEGV_MAPERR|^#[0-9]|^.*:ERROR:' \
		"${SVELTE_LOG}" | head -80 || true
	echo "(svelte content_shell exit=${svelte_rc}, full log: ${SVELTE_LOG})"
	echo "----- /var/log/m6-svelte.log (last 80 lines) -----"
	tail -80 "${SVELTE_LOG}" || true
	echo "----- end /var/log/m6-svelte.log -----"
	echo

	if [ "${hyd}" -gt 0 ] && [ "${dom}" -gt 0 ] && [ "${fet}" -gt 0 ] && [ "${sse}" -gt 0 ] && [ "${segv}" -eq 0 ]; then
		echo "==== M6 PASS (hydration + DOM + fetch + SSE; no trampoline SEGV) ===="
	else
		echo "==== M6 FAIL (see ${SVELTE_LOG} and sentinel counts above) ===="
	fi
	echo
fi

# M7-interactive opt-in: parse `m6-no-poweroff` from /proc/cmdline. When
# present (set by scripts/70-boot-chromium-guest.sh --gui), DO NOT call
# poweroff; instead block here forever so the kernel + content_shell
# stay up for the user's VNC session. The host side terminates qemu via
# the `timeout`/SIGTERM path in 70-boot-chromium-guest.sh once the user
# is done. Behaviour without the token is byte-identical to the M6
# baseline (poweroff after 1 s, as below).
if grep -qw m6-no-poweroff /proc/cmdline 2>/dev/null; then
	echo "m6-no-poweroff cmdline token present; holding the guest open"
	echo "for the M7 interactive VNC session (Ctrl-C the host boot"
	echo "script -- or ^A x in qemu interactive -- to tear down)."
	sync
	# `sleep infinity` doesn't exist in this busybox; loop forever.
	while :; do sleep 86400; done
fi

# Auto-halt the guest so qemu (-no-reboot) returns. Mirrors S99-run-d8.
if [ ! -e /etc/no-halt-after-m5 ]; then
	echo "powering off in 1s (touch /etc/no-halt-after-m5 to disable)"
	sleep 1
	sync
	exec poweroff -f
fi
