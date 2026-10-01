#!/usr/bin/env bash
# The CI security gate over the planned infrastructure, in two halves:
#
# 1. The real plan (scripts/offline-plan.sh) must have no failing finding.
# 2. The gate must not be blind to this module. A passing scan proves
#    nothing if the scanner can't read how the module is written, and
#    tfwarden could not, before v0.2.0: it read only inline security-group
#    rules, and resources inside a module never matched their own
#    configuration. So a copy of the plan has the database's ingress rule
#    opened to the internet, and tfwarden must fail it.
set -euo pipefail
cd "$(dirname "$0")/.."
tfwarden="${TFWARDEN:-tfwarden}"

echo "== real plan"
"$tfwarden" scan plan.json

echo "== same plan, database rule opened to 0.0.0.0/0: must fail"
node -e '
  const plan = JSON.parse(require("fs").readFileSync("plan.json", "utf8"));
  const addr = "module.hookrelay.aws_vpc_security_group_ingress_rule.db_from_tasks[\"api\"]";
  const rc = plan.resource_changes.find((r) => r.address === addr);
  if (!rc) { console.error("no " + addr + " in plan.json"); process.exit(2); }
  rc.change.after.cidr_ipv4 = "0.0.0.0/0";
  rc.change.after.referenced_security_group_id = null;
  rc.change.after_unknown.referenced_security_group_id = false;
  process.stdout.write(JSON.stringify(plan));
' > plan-opened.json
trap 'rm -f plan-opened.json' EXIT

set +e
out="$("$tfwarden" scan plan-opened.json)"
code=$?
set -e
echo "$out"
if [ "$code" -ne 1 ] || ! grep -q 'db_from_tasks\["api"\].*ingress from 0.0.0.0/0 allows PostgreSQL (port 5432)' <<<"$out"; then
  echo "tfwarden did not fail the opened database rule: the gate is blind to this module" >&2
  exit 1
fi
echo "== gate verified: it sees this module's rules"
