#!/usr/bin/env bash
# Tries to create an Always Free Oracle ARM server.
# "Out of capacity" is normal: it just exits quietly and tries again next run.
set -uo pipefail

: "${OCI_TENANCY_OCID:?missing secret OCI_TENANCY_OCID}"
: "${SSH_PUBLIC_KEY:?missing secret SSH_PUBLIC_KEY}"

T="$OCI_TENANCY_OCID"
NAME="${INSTANCE_NAME:-Minecraft-Ai-VM}"
SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCPUS:-2}"
MEM="${MEMORY_GB:-12}"

summary() { echo "$*"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# 1. Already have one? Then nothing to do.
existing=$(oci compute instance list -c "$T" --display-name "$NAME" --all 2>/dev/null \
  | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty')
if [ -n "$existing" ]; then
  summary "✅ Server '$NAME' already exists. Find its IP in the Oracle console (Compute → Instances)."
  exit 0
fi

# 2. Find (or create) a network to put it in.
subnet=$(oci network subnet list -c "$T" --all | jq -r '.data[0].id // empty')
if [ -z "$subnet" ]; then
  echo "No subnet found, creating a network..."
  vcn_json=$(oci network vcn create -c "$T" --cidr-blocks '["10.0.0.0/16"]' --display-name Minecraft-VCN --dns-label minecraftvcn --wait-for-state AVAILABLE) || exit 1
  vcn=$(jq -r '.data.id' <<<"$vcn_json")
  rt=$(jq -r '.data."default-route-table-id"' <<<"$vcn_json")
  igw=$(oci network internet-gateway create -c "$T" --vcn-id "$vcn" --is-enabled true --display-name Minecraft-IGW \
        --wait-for-state AVAILABLE | jq -r '.data.id') || exit 1
  oci network route-table update --rt-id "$rt" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"networkEntityId\":\"$igw\"}]" >/dev/null || exit 1
  subnet=$(oci network subnet create -c "$T" --vcn-id "$vcn" --cidr-block 10.0.0.0/24 --display-name Minecraft-Public-Subnet --dns-label public \
           --wait-for-state AVAILABLE | jq -r '.data.id') || exit 1
fi

# 3. Latest Ubuntu 24.04 Minimal image for ARM (aarch64).
image=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "24.04 Minimal aarch64" \
        --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all | jq -r '.data[0].id // empty')
if [ -z "$image" ]; then  # fall back to any 24.04 Minimal aarch64 build
  image=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --shape "$SHAPE" \
          --sort-by TIMECREATED --sort-order DESC --all \
          | jq -r '[.data[] | select(."display-name" | test("24.04-Minimal-aarch64"))][0].id // empty')
fi
[ -z "$image" ] && { echo "Could not find an Ubuntu image"; exit 1; }

# Keep just "<type> <key>" so stray line breaks or comments from copy/paste don't break it.
clean_key=$(tr -s '[:space:]' ' ' <<<"$SSH_PUBLIC_KEY" | grep -oE '(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+' | head -1)
[ -z "$clean_key" ] && { summary "❌ SSH_PUBLIC_KEY secret doesn't look like an SSH public key (should start with ssh-ed25519)"; exit 1; }
echo "$clean_key" > /tmp/ssh_key.pub

# Opens one GitHub issue for a real error (skips if the bot already has one open) so you get pinged.
# Public repo: only issues opened by the bot itself count, so a stranger's issue can't hide a real alert,
# and Oracle's raw error text stays out of the issue (the run log has it, with secrets masked).
report_error() {
  summary "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  if [ -n "${GH_TOKEN:-}" ]; then
    if [ -z "$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --author app/github-actions --search 'in:title "Oracle bot error"' --json number -q '.[].number')" ]; then
      gh issue create --repo "$GITHUB_REPOSITORY" --assignee "$GITHUB_REPOSITORY_OWNER" --title "⚠️ Oracle bot error: $1" \
        --body "Check the log: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
        || echo "(couldn't open error issue)"
    fi
  fi
  exit 1
}

# 4. Keep trying every availability domain about once a minute for TRY_MINUTES.
# Timing knobs (the timing test sets these per run; defaults are the normal timing):
#   PAUSE    seconds to wait between rounds of zone tries
#   BACKOFF  seconds to wait after Oracle says "too many requests" (429)
#   ZONE_GAP seconds to wait between zones inside a round
PAUSE=${PAUSE:-60}; BACKOFF=${BACKOFF:-180}; ZONE_GAP=${ZONE_GAP:-0}
echo "Timing: pause=${PAUSE}s backoff=${BACKOFF}s zone_gap=${ZONE_GAP}s"
rate_limited=0
attempts=0
tries=0
limits=0
ads=$(oci iam availability-domain list -c "$T" | jq -r '.data[].name')
end=$((SECONDS + ${TRY_MINUTES:-12} * 60))
while [ "$SECONDS" -lt "$end" ]; do
attempts=$((attempts + 1))
pause=$PAUSE
for ad in $ads; do
  echo "[$(date -u +%H:%M:%S)] Try $attempts: $ad ($OCPUS OCPU / ${MEM}GB)..."
  tries=$((tries + 1))
  if out=$(oci --no-retry compute instance launch -c "$T" --availability-domain "$ad" --display-name "$NAME" \
        --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
        --image-id "$image" --subnet-id "$subnet" --assign-public-ip true \
        --ssh-authorized-keys-file /tmp/ssh_key.pub --wait-for-state RUNNING 2>&1); then
    # Public repo: the IP is not printed anywhere here. Get it from the Oracle console.
    summary "🎉 GOT IT! Server '$NAME' created. Find its public IP in the Oracle console (Compute → Instances)."
    # Open an issue so GitHub notifies you (email + app).
    if [ -n "${GH_TOKEN:-}" ]; then
      gh issue create --repo "$GITHUB_REPOSITORY" --assignee "$GITHUB_REPOSITORY_OWNER" --title "🎉 Oracle server is ready!" \
        --body "Your free Oracle server '$NAME' was created. Get its public IP from the Oracle console (Compute → Instances), then log in with user \`ubuntu\` and your SSH key." \
        || echo "(couldn't open notification issue)"
    fi
    exit 0
  fi
  code=$(sed -n '/^{/,$p' <<<"$out" | jq -r '.code // empty' 2>/dev/null)
  status=$(sed -n '/^{/,$p' <<<"$out" | jq -r '.status // empty' 2>/dev/null)
  if grep -qiE 'out of (host )?capacity' <<<"$out"; then
    echo "  -> no capacity right now"
  elif [ "$status" = "429" ] || grep -qi 'TooManyRequests' <<<"$out"; then
    echo "  -> RATE LIMITED (429 too many requests), slowing down"; rate_limited=1; limits=$((limits + 1)); pause=$BACKOFF
  elif [ "$status" = "500" ] || grep -qi 'InternalError' <<<"$out"; then
    echo "  -> Oracle internal error (500), treating as no capacity"
  else
    report_error "${status:-?} ${code:-unknown}" "$out"
  fi
  [ "$ZONE_GAP" -gt 0 ] && [ "$SECONDS" -lt "$end" ] && sleep "$ZONE_GAP"
done
[ "$SECONDS" -lt "$end" ] && sleep "$pause"
done

# One machine-readable line for the timing test sheet.
echo "STATS tries=$tries limits=$limits pause=$PAUSE backoff=$BACKOFF gap=$ZONE_GAP"
if [ "$rate_limited" = 1 ]; then
  summary "⚠️ RATE LIMITED: Oracle said too many requests (429). Will try again next run."
else
  summary "⏳ Tried every zone $attempts times: no capacity. Will try again next run."
fi
exit 0
