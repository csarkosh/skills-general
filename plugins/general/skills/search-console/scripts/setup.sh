#!/usr/bin/env bash
# setup.sh: create the read-only Search Console service account and its key.
#
# Idempotent: it skips whatever already exists and never overwrites a key unless
# you pass --rotate. It grants the service account no IAM role on the project;
# all of its access comes from the Search Console grant you make by hand at the
# end, which this script prints the click-path for.
#
# Usage:
#   setup.sh --project <gcp-project> [--account gsc-reader] [--key <path>] [--rotate]
#
# Defaults: account gsc-reader, key ~/.config/<project>/gsc-sa.json (or $GSC_SA_KEY).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${GSC_PROJECT:-}"
ACCOUNT="gsc-reader"
KEY=""
ROTATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --key)     KEY="${2:-}"; shift 2 ;;
    --rotate)  ROTATE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "  FAIL  unknown option $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "  FAIL  no project: pass --project <gcp-project> or set \$GSC_PROJECT" >&2
  exit 1
fi
if ! command -v gcloud >/dev/null 2>&1; then
  echo "  FAIL  gcloud is not installed: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi

KEY="${KEY:-${GSC_SA_KEY:-$HOME/.config/$PROJECT/gsc-sa.json}}"
EMAIL="$ACCOUNT@$PROJECT.iam.gserviceaccount.com"

# 1. The API.
if gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' \
     | grep -qx 'searchconsole.googleapis.com'; then
  echo "  ok    searchconsole.googleapis.com already enabled on $PROJECT"
else
  echo "  ..    enabling searchconsole.googleapis.com on $PROJECT"
  gcloud services enable searchconsole.googleapis.com --project="$PROJECT"
fi

# 2. The service account. No IAM role: Search Console grants its access, not GCP.
if gcloud iam service-accounts describe "$EMAIL" --project="$PROJECT" >/dev/null 2>&1; then
  echo "  ok    service account $EMAIL already exists"
else
  echo "  ..    creating service account $ACCOUNT"
  gcloud iam service-accounts create "$ACCOUNT" \
    --display-name="Search Console reader" --project="$PROJECT"
fi

# 3. The key.
if [ -f "$KEY" ] && [ "$ROTATE" -eq 0 ]; then
  echo "  ok    key already present at $KEY (pass --rotate to replace it)"
else
  if [ -f "$KEY" ]; then
    echo "  ..    rotating the key at $KEY"
    mv "$KEY" "$KEY.$(date +%Y%m%d%H%M%S).bak"
  fi
  mkdir -p "$(dirname "$KEY")"
  gcloud iam service-accounts keys create "$KEY" --iam-account="$EMAIL" --project="$PROJECT"
  chmod 600 "$KEY"
  echo "  ok    key written to $KEY (chmod 600, outside any repo, never commit it)"
fi

cat <<EOF

One manual step is left, because Search Console has no API for granting access:

  1. Open https://search.google.com/search-console
  2. Select the property (a Domain property is the bare host, e.g. example.com)
  3. Settings > Users and permissions > Add user
  4. Email: $EMAIL
  5. Permission: Full   (Restricted cannot submit sitemaps)
  6. Add

Then check it works:

  GSC_SA_KEY=$KEY "$HERE/gsc.py" sitemap
EOF
