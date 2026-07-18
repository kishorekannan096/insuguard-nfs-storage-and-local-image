#!/usr/bin/env bash
# Read-only discovery helper for making this chart fully air-gapped.
#
# It answers three questions we can't answer from the chart repo alone
# because they depend on what's actually sitting in this cluster's NFS-
# backed model caches:
#
#   1. The real modelProfile UUID for nemoretrieverParser/llamaParser/
#      nemotronVlm — read the cached profile directory name straight off
#      each nim-cache PVC (no NIM/NGC involvement, just a directory listing).
#   2. nvclip's Triton model repository config.pbtxt — ground-truths the
#      adapter's tensor-name/shape assumptions in
#      files/nvclip-adapter/adapter.py (though the adapter itself re-reads
#      this live via Triton's metadata API, so it doesn't strictly need this
#      — this is for a human to sanity-check the same information).
#   3. claims-backend's actual NVCLIP_URL request/response contract — grep
#      its own filesystem for how it calls nvclip, since that's the contract
#      the adapter has to preserve.
#
# It creates one short-lived, read-only debug pod that mounts the existing
# PVCs (no write access requested), and deletes it when done. It does not
# touch the Deployments, install anything, or need nvidiaApiKey/NGC access —
# it only reads what's already on disk.
#
# Usage: ./discover-airgap-info.sh <namespace>

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace>}"
LABEL_SELECTOR="app.kubernetes.io/part-of=insurguard"
DEBUG_POD="insurguard-airgap-discovery"

command -v oc >/dev/null 2>&1 || { echo "oc CLI not found on PATH" >&2; exit 1; }

echo "== Discovering this release's PVCs in namespace '$NAMESPACE' =="
mapfile -t PVCS < <(oc get pvc -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "${#PVCS[@]}" -eq 0 ]; then
  echo "No PVCs found with label $LABEL_SELECTOR in $NAMESPACE — is the release installed there?" >&2
  exit 1
fi
printf ' - %s\n' "${PVCS[@]}"

# Only care about the 4 NIM caches for this discovery pass.
declare -A WANT=( [nemoretriever-parser]=1 [llama-parser]=1 [nemotron-vlm]=1 [nvclip]=1 )
VOLUMES_YAML=""
MOUNTS_YAML=""
for pvc in "${PVCS[@]}"; do
  for comp in "${!WANT[@]}"; do
    if [[ "$pvc" == *"nim-cache-$comp" ]]; then
      vol="vol-$comp"
      VOLUMES_YAML+="  - name: $vol
    persistentVolumeClaim:
      claimName: $pvc
      readOnly: true
"
      MOUNTS_YAML+="        - name: $vol
          mountPath: /mnt/$comp
          readOnly: true
"
    fi
  done
done

if [ -z "$VOLUMES_YAML" ]; then
  echo "None of the nim-cache PVCs (nemoretriever-parser/llama-parser/nemotron-vlm/nvclip) were found." >&2
  exit 1
fi

echo
echo "== Launching read-only debug pod '$DEBUG_POD' =="
cat <<EOF | oc apply -n "$NAMESPACE" -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $DEBUG_POD
  labels:
    app: $DEBUG_POD
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: discover
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
$MOUNTS_YAML
  volumes:
$VOLUMES_YAML
EOF

cleanup() {
  echo
  echo "== Cleaning up debug pod =="
  oc delete pod "$DEBUG_POD" -n "$NAMESPACE" --ignore-not-found=true >/dev/null
}
trap cleanup EXIT

echo "Waiting for it to be ready..."
oc wait --for=condition=Ready "pod/$DEBUG_POD" -n "$NAMESPACE" --timeout=120s

echo
echo "== 1. modelProfile candidates (UUID-looking directories under each NIM cache) =="
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
for comp in nemoretriever-parser llama-parser nemotron-vlm nvclip; do
  echo "--- $comp (mounted at /mnt/$comp) ---"
  oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
    "find /mnt/$comp -mindepth 1 -maxdepth 4 -type d 2>/dev/null | grep -E '$UUID_RE' || echo '  (no UUID-looking directories found — inspect manually: oc exec $DEBUG_POD -n $NAMESPACE -- find /mnt/$comp -maxdepth 4)'"
done

echo
echo "== 2. nvclip Triton model repository config.pbtxt (ground-truths adapter.py's assumptions) =="
oc exec -n "$NAMESPACE" "$DEBUG_POD" -- sh -c \
  "find /mnt/nvclip/triton-model-repository -maxdepth 3 -iname 'config.pbtxt' 2>/dev/null -exec echo '--- {} ---' \; -exec cat {} \; || echo '  not found — check /mnt/nvclip/triton-model-repository layout manually'"

echo
echo "== 3. claims-backend's actual nvclip request contract (best-effort grep of its own filesystem) =="
BACKEND_POD=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=claims-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$BACKEND_POD" ]; then
  echo "Found running claims-backend pod: $BACKEND_POD"
  oc exec -n "$NAMESPACE" "$BACKEND_POD" -- sh -c \
    "grep -rniE 'nvclip|NVCLIP_URL' /app 2>/dev/null | grep -viE '\.pyc' | head -50 || echo '  no matches under /app — adjust the search path for this image's layout'"
else
  echo "No running claims-backend pod found in $NAMESPACE — skip, or run:"
  echo "  oc exec -n $NAMESPACE <claims-backend-pod> -- grep -rniE 'nvclip|NVCLIP_URL' /app"
fi

echo
echo "== Next steps =="
cat <<'EOF'
1. Take the modelProfile UUIDs from section 1 and set them:
     --set nemoretrieverParser.modelProfile=<uuid> \
     --set llamaParser.modelProfile=<uuid> \
     --set nemotronVlm.modelProfile=<uuid>
   (nvclip's UUID in values.yaml was already captured this way previously —
   re-run this against nvclip's cache too if the image tag ever changes.)

2. Compare section 2's real config.pbtxt input/output tensor names against
   what files/nvclip-adapter/adapter.py discovers live at request time (it
   should match automatically — this is just a human sanity check) and
   confirm the input shape's H/W matches CLIP_MEAN/CLIP_STD's assumption of
   standard OpenCLIP preprocessing.

3. Compare section 3's actual request/response shape against what
   files/nvclip-adapter/adapter.py implements for POST /v1/embeddings. If
   claims-backend expects a different path, request shape, or response
   shape, the adapter needs adjusting to match BEFORE relying on it for
   real fraud-detection decisions.

4. If you have a way to run nvclip in NIM-wrapper mode once (temporary
   nvidiaApiKey + airgappedTritonMode=false) with network access, POST the
   same test image to both the NIM wrapper and the airgappedTritonMode
   adapter and diff the embeddings (cosine similarity should be ~1.0). That
   closes the loop on whether the adapter's preprocessing assumptions are
   actually correct, not just plausible.
EOF
