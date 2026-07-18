#!/usr/bin/env bash
# Same discovery as discover-airgap-info.sh, but reads the NFS export
# directly (run this ON the NFS server, or from a host with the export
# mounted) instead of going through oc/a debug pod. Needs no cluster access,
# no running release, no nvidiaApiKey — just filesystem read access to
# whatever's already been cached there.
#
# Relies on the nfs.io/storage-path annotation in templates/nim-cache-pvcs.yaml
# et al. pinning each PVC to a fixed, predictable subdirectory name
# (understood by nfs-subdir-external-provisioner): under the export root you
# should find directories literally named
#   insurguard-nim-cache-nemoretriever-parser
#   insurguard-nim-cache-llama-parser
#   insurguard-nim-cache-nemotron-vlm
#   insurguard-nim-cache-nvclip
#
# Usage: ./discover-nfs-direct.sh <path-to-nfs-export-root>
#   e.g. ./discover-nfs-direct.sh /export/insurguard
#   e.g. ./discover-nfs-direct.sh /mnt/nfs-share   (if mounted locally)

set -euo pipefail

ROOT="${1:?Usage: $0 <path-to-nfs-export-root>}"
[ -d "$ROOT" ] || { echo "'$ROOT' is not a directory — check the export path (see /etc/exports on the NFS server)" >&2; exit 1; }

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

echo "== Looking for insurguard-nim-cache-* directories under $ROOT =="
mapfile -t CACHE_DIRS < <(find "$ROOT" -maxdepth 1 -type d -name 'insurguard-nim-cache-*' | sort)
if [ "${#CACHE_DIRS[@]}" -eq 0 ]; then
  echo "None found directly under $ROOT. Either:"
  echo " - nothing has been cached here yet (no NIM has ever run against this export), or"
  echo " - the provisioner nests things one level deeper than expected — try:"
  echo "     find '$ROOT' -maxdepth 2 -type d -iname '*nim-cache*'"
  exit 1
fi
printf ' - %s\n' "${CACHE_DIRS[@]}"

echo
echo "== 1. modelProfile candidates (UUID-looking directories under each NIM cache) =="
for comp in nemoretriever-parser llama-parser nemotron-vlm nvclip; do
  dir="$ROOT/insurguard-nim-cache-$comp"
  echo "--- $comp ($dir) ---"
  if [ -d "$dir" ]; then
    find "$dir" -mindepth 1 -maxdepth 4 -type d 2>/dev/null | grep -E "$UUID_RE" \
      || echo "  (no UUID-looking directories found — inspect manually: find '$dir' -maxdepth 4)"
  else
    echo "  (directory not found — this NIM's cache is empty/never seeded)"
  fi
done

echo
echo "== 2. nvclip Triton model repository config.pbtxt =="
nvclip_dir="$ROOT/insurguard-nim-cache-nvclip"
if [ -d "$nvclip_dir" ]; then
  find "$nvclip_dir" -path '*/triton-model-repository/*' -iname 'config.pbtxt' 2>/dev/null \
    -exec sh -c 'echo "--- {} ---"; cat "{}"' \; \
    || echo "  not found — check layout manually: find '$nvclip_dir' -maxdepth 3"
else
  echo "  (nvclip cache directory not found)"
fi

echo
echo "== Next steps =="
cat <<'EOF'
1. Take the modelProfile UUIDs from section 1 and set them:
     --set nemoretrieverParser.modelProfile=<uuid> \
     --set llamaParser.modelProfile=<uuid> \
     --set nemotronVlm.modelProfile=<uuid>

2. Compare section 2's real config.pbtxt input/output tensor names against
   what files/nvclip-adapter/adapter.py discovers live at request time (it
   should match automatically — this is just a human sanity check) and
   confirm the input shape's H/W matches CLIP_MEAN/CLIP_STD's assumption of
   standard OpenCLIP preprocessing.

3. claims-backend's actual nvclip request contract still needs checking
   against a running pod (this script has no cluster access to check it) —
   see discover-airgap-info.sh section 3, or once installed:
     oc exec -n <namespace> <claims-backend-pod> -- grep -rniE 'nvclip|NVCLIP_URL' /app

4. If nothing was found in section 1 at all, these NIMs have never been run
   against this export — you're on the bootstrap-install path (temporary
   nvidiaApiKey) from earlier, not discovery.
EOF
