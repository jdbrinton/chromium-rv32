#!/bin/sh
# Milestone 2 acceptance script. Prints a banner so the harness can
# detect a successful boot, runs d8 on the canonical hello.js, then
# prints a closing banner with the exit code.

set -u

cd /opt/v8

echo
echo "==== chromium-rv32 M2 acceptance ===="
echo "uname:       $(uname -a)"
echo "isa:         $(grep -m1 isa /proc/cpuinfo | sed 's/.*: //')"
echo "mmu/uarch:   $(grep -m1 uarch /proc/cpuinfo | sed 's/.*: //')"
echo "ram free:    $(grep MemAvailable /proc/meminfo)"
echo "d8 path:     $(realpath ./d8)"
echo "d8 size:     $(wc -c < ./d8) bytes"
echo
echo "----- hello.js -----"
./d8 ./hello.js
rc=$?
echo "----- /hello.js (exit=$rc) -----"
echo

echo "----- inline JS smoke -----"
./d8 -e '
const t0 = Date.now();
let s = 0;
for (let i = 1; i <= 100000; i++) s += i;
print("sum 1..1e5 =", s);
print("Math.sqrt(2) =", Math.sqrt(2));
print("typeof WebAssembly =", typeof WebAssembly);
print("WebAssembly.validate =", typeof WebAssembly.validate);
async function tick() {
  const v = await new Promise(r => setTimeout(() => r(42), 1));
  print("async/Promise -> ", v);
}
tick();
print("walltime ms:", Date.now() - t0);
'
rc2=$?
echo "----- end inline (exit=$rc2) -----"
echo

echo "----- network smoke -----"
# In qemu's user-mode networking, the host is reachable at 10.0.2.2 and
# DNS is 10.0.2.3 (matches the udhcpc DHCP lease we got at boot).
# If the M5 demo server is running on the host at :3000 we exercise it.
# Otherwise the test reports SKIP and we still count it as a pass.
HOST_GW="10.0.2.2"
DEMO_URL="http://${HOST_GW}:3000/api/echo"

rc3=0
if wget -q -T 2 -O - "${HOST_GW}:3000/api/healthz" 2>/dev/null \
		| head -c 80 >/tmp/healthz.txt; then
	echo "M5 host server reachable at ${HOST_GW}:3000"
	cat /tmp/healthz.txt; echo
	# POST a payload to /api/echo and confirm round-trip.
	cat >/tmp/payload.json <<EOF
{"from":"rv32-guest","kernel":"$(uname -r)","d8":"$(./d8 -e 'print(version())' 2>/dev/null | head -1)"}
EOF
	wget -q -T 5 -O /tmp/echo.json \
		--header='Content-Type: application/json' \
		--post-file=/tmp/payload.json \
		"${DEMO_URL}" || rc3=$?
	if [ "$rc3" -eq 0 ]; then
		echo "POST ${DEMO_URL}:"
		head -c 400 /tmp/echo.json; echo
	fi
else
	echo "M5 host server not reachable at ${HOST_GW}:3000 (SKIP)"
	echo "(start it on the host with: cd chromium-rv32/server && npm run start)"
fi
echo "----- end network (exit=$rc3) -----"
echo

if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ]; then
	echo "==== M2 PASS ===="
else
	echo "==== M2 FAIL (hello=$rc inline=$rc2) ===="
fi
echo

# Auto-halt the guest so qemu (-no-reboot) returns. Skipped if the file
# /etc/no-halt-after-d8 exists (lets the user keep the console open).
if [ ! -e /etc/no-halt-after-d8 ]; then
	echo "powering off in 1s (touch /etc/no-halt-after-d8 to disable)"
	sleep 1
	# Sync everything just to be safe, then halt via the SBI test
	# device qemu maps for us.
	sync
	exec poweroff -f
fi
