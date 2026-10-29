#!/usr/bin/env bash
# End-to-end test of the sale and verification page on a local fork of BSC.
# Needs: Foundry (anvil, forge, cast), Python 3 with playwright, and ethers.umd.min.js (npm i ethers@6.13.4).
#   web/run_e2e.sh path/to/ethers.umd.min.js
set -uo pipefail
cd "$(dirname "$0")/.."
ETHERS="$(realpath "$1")"
R=http://127.0.0.1:8546
OUT="$(mktemp -d)"
mkdir -p "$OUT/shots"

# a node that keeps older state: free nodes that keep only the last minute of state break long forks
FORK_URL="${FORK_URL:-https://bsc-mainnet.public.blastapi.io}"
anvil --fork-url "$FORK_URL" --port 8546 --silent >/dev/null 2>&1 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; kill $HTTP 2>/dev/null || true' EXIT
until curl -s -m 1 -X POST -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' $R | grep -q result; do sleep 0.5; done

newkey() { cast wallet new --json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["private_key"])'; }
K1=$(newkey); K2=$(newkey); KB=$(newkey)
A1=$(cast wallet address $K1); A2=$(cast wallet address $K2); B=$(cast wallet address $KB)
for A in $A1 $A2 $B; do cast rpc anvil_setBalance $A 0x56BC75E2D63100000 --rpc-url $R >/dev/null; done
cast rpc anvil_impersonateAccount $B --rpc-url $R >/dev/null

REG=$(forge create src/CuratedRegistry.sol:CuratedRegistry --rpc-url $R --private-key $K1 --broadcast \
  --constructor-args 0x68224F668083c29e9800Be2a646d42d18cedF7e2 2>&1 | awk '/Deployed to/{print $3}')
NOW=$(cast block latest --field timestamp --rpc-url $R)

python3 - "$REG" "$A1" "$B" "$NOW" <<'EOF'
import json, sys
reg, cur, buyer, now = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
s = json.load(open("tool/examples/collection.json"))
s.update(registry=reg, curator=cur, saleStart=now + 3600, saleEnd=now + 30 * 86400,
         presale={"start": now - 60, "allowlist": [{"address": buyer, "quota": 1}]})
# hostile text that the curator really published (and committed on chain): it must render as plain text
s["works"][2]["title"] = '<img src=x onerror="window.__xss=1">'
s["story"] = '<script>window.__xss=2</script> test story'

json.dump(s, open("tool/examples/_e2e_spec.json", "w"))
EOF
M=test/fixtures/_e2e_manifest.json
python3 tool/curate.py build tool/examples/_e2e_spec.json $M --rpc $R >/dev/null
CIR=$(MANIFEST=$M forge script script/Launch.s.sol --fork-url $R --broadcast --private-key $K1 2>&1 | awk '/CIRCUITS/{print $2}' | head -1)
echo "registry $REG  circuits $CIR"
# the tool's on-chain audit must accept the published manifest, metadata commitment included
python3 tool/curate.py checkroot $M --rpc $R --registry $REG --circuits $CIR > "$OUT/checkroot.json"
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["ok"] else 1)' "$OUT/checkroot.json"; then
  echo "PASS checkroot against the chain"
else
  echo "FAIL checkroot against the chain"; cat "$OUT/checkroot.json"; CHECKROOT_FAILED=1
fi

# serve the page, its config and the manifest
mkdir -p "$OUT/site"
cp web/index.html web/app.js "$OUT/site/"
cp $M "$OUT/site/manifest.json"
site() { printf '{"manifest":"%s","registry":"%s","circuits":"%s","rpc":"%s","chainId":56}\n' "$1" "$REG" "$CIR" "$R"; }
site manifest.json > "$OUT/site/site.json"
# altered manifests: a changed price or a changed title must be refused
python3 - "$M" "$OUT/site" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
t = json.loads(json.dumps(m)); t["works"][1]["priceWei"] = "1"
json.dump(t, open(sys.argv[2] + "/tampered.json", "w"))
x = json.loads(json.dumps(m)); x["works"][3]["title"] = "XOR (signed by the artist)"
json.dump(x, open(sys.argv[2] + "/retitled.json", "w"))
PY
site tampered.json > "$OUT/site/site-tampered.json"
site retitled.json > "$OUT/site/site-retitled.json"
python3 - "$M" "$OUT/site" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["launch"]["curator"] = "0x000000000000000000000000000000000000beef"
json.dump(m, open(sys.argv[2] + "/othercurator.json", "w"))
PY
site othercurator.json > "$OUT/site/site-othercurator.json"
if curl -s -m 1 http://127.0.0.1:8780/ >/dev/null; then echo "port 8780 is already in use" >&2; exit 1; fi
python3 -m http.server 8780 --directory "$OUT/site" >/dev/null 2>&1 &
HTTP=$!
sleep 1

cast rpc anvil_impersonateAccount $A2 --rpc-url $R >/dev/null
cast rpc anvil_impersonateAccount $A1 --rpc-url $R >/dev/null
python3 web/e2e_test.py "http://127.0.0.1:8780/" "$B" "$OUT/shots" "$ETHERS" "$CIR" "$A2" "$M" "$A1"
STATUS=$?
[ -n "${CHECKROOT_FAILED:-}" ] && STATUS=1
rm -f tool/examples/_e2e_spec.json $M
echo "screenshots: $OUT/shots"
exit $STATUS
