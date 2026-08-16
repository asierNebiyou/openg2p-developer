#!/usr/bin/env bash
# Map setup profiles to repository keys cloned by scripts/clone-repos.sh.

clone_profile_normalize() {
  local profile="${1:-registry}"
  profile="$(printf '%s' "$profile" | tr '[:upper:]' '[:lower:]')"
  profile="${profile//_/-}"
  case "$profile" in
    nsr) echo "national-social-registry" ;;
    farmer) echo "farmer-registry" ;;
    vsss) echo "village-social-security-registry" ;;
    *) echo "$profile" ;;
  esac
}

clone_profile_list() {
  cat <<'EOF'
Profiles (use with make clone PROFILE=... or make setup PROFILE=...):

  registry                  Shared Registry Gen2 core + Farmer + NSR + sample data
  national-social-registry  NSR only (platform, IAM, AWE, UI, NSR, sample data)
  village-social-security-registry  VSSS only (platform, IAM, AWE, UI, VSSS)
  farmer-registry           Farmer Registry only (platform, IAM, AWE, UI, farmer)
  pbms                      Odoo / PBMS stack + Farmer Registry (for bg tasks)
  bridge                    G2P Bridge only
  spar                      SPAR only
  infra                     No product repos (infra is Docker-only)
  full                      All product repositories
EOF
}

clone_profile_repo_keys() {
  local profile
  profile="$(clone_profile_normalize "${1:-registry}")"

  case "$profile" in
    infra)
      ;;
    farmer-registry)
      echo "registry_platform iam_service master_data_service awe farmer_registry openg2p_data"
      ;;
    national-social-registry)
      echo "registry_platform iam_service master_data_service awe national_social_registry openg2p_data"
      ;;
    village-social-security-registry)
      echo "registry_platform iam_service master_data_service awe village_social_security_registry openg2p_data"
      ;;
    registry)
      echo "registry_platform iam_service master_data_service awe farmer_registry national_social_registry village_social_security_registry openg2p_data"
      ;;
    pbms)
      echo "odoo pbms odoo_commons registry_platform iam_service master_data_service awe farmer_registry openg2p_data"
      ;;
    bridge)
      echo "g2p_bridge"
      ;;
    spar)
      echo "spar"
      ;;
    full)
      echo "odoo pbms odoo_commons registry_platform iam_service master_data_service openg2p_data farmer_registry national_social_registry village_social_security_registry g2p_bridge spar awe"
      ;;
    *)
      echo "Unknown PROFILE '${1}'. Valid profiles:" >&2
      clone_profile_list >&2
      return 1
      ;;
  esac
}
