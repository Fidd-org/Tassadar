#!/usr/bin/env bash
# Read-only capacity check: only public size/region/price metadata is printed.
set -euo pipefail
case "$OPERATION" in
  plan|apply) ;;
  destroy|destroy-plan) exit 0 ;;
  *) echo '::error::Unknown capacity-check operation'; exit 1 ;;
esac

requests="$(tofu show -json "$RUNNER_TEMP/tassadar-infra/plan.tfplan" | jq -c '
  [.resource_changes[]? | select(.mode == "managed" and .type == "digitalocean_droplet")
   | select(.change.actions | index("create")) | .change.after | {region, size}]
  | group_by([.region, .size]) | map({region: .[0].region, slug: .[0].size, count: length})')"
if [[ "$requests" == '[]' ]]; then
  echo 'No Droplet creation in the plan; capacity check skipped.'
  exit 0
fi
if [[ -z "${TF_VAR_digitalocean_token:-}" ]]; then
  echo '::error::DigitalOcean token is required for the capacity check'
  exit 1
fi

sizes='[]'
next_url='https://api.digitalocean.com/v2/sizes?per_page=200'
for ((page = 0; page < 10 && ${#next_url} > 0; page++)); do
  case "$next_url" in
    https://api.digitalocean.com/v2/sizes\?*) ;;
    *) echo '::error::Unexpected DigitalOcean pagination URL'; exit 1 ;;
  esac
  response="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --retry 2 \
    --header "Authorization: Bearer $TF_VAR_digitalocean_token" "$next_url")"
  jq -e '.sizes | type == "array"' <<< "$response" > /dev/null
  sizes="$(jq -cn --argjson old "$sizes" --argjson page "$response" '$old + $page.sizes')"
  next_url="$(jq -r '.links.pages.next // empty' <<< "$response")"
done
if [[ -n "$next_url" ]]; then
  echo '::error::DigitalOcean size pagination exceeded its limit'
  exit 1
fi

report="$(jq -cn --argjson sizes "$sizes" --argjson requests "$requests" '
  $requests | map(. as $r |
    ($sizes | map(select(.slug == $r.slug)) | first) as $wanted |
    {region: $r.region, slug: $r.slug, count: $r.count,
     available: ($wanted != null and $wanted.available == true and (($wanted.regions // []) | index($r.region)) != null),
     price_monthly: $wanted.price_monthly,
     alternatives: ([$sizes[] | select(.available == true and (.regions | index($r.region)) != null)
       | select(if $wanted != null then .memory == $wanted.memory and .vcpus == $wanted.vcpus
                else .memory <= 4096 and .vcpus <= 2 end)
       | {slug, memory, vcpus, price_monthly, price_hourly}] | sort_by(.price_monthly) | .[:5])})')"
jq -c '.[]' <<< "$report"
if ! jq -e 'all(.[]; .available == true)' <<< "$report" > /dev/null; then
  echo '::error::Planned Droplet sizes are unavailable in the selected region; choose an available size before apply'
  exit 1
fi
