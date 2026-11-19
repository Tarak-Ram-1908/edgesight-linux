#!/usr/bin/env bash
# Verifies that every option requested in the kernel fragments survived Kconfig
# dependency resolution (Kconfig silently drops options whose dependencies are unmet).
# Fragments are merged in order, so for an option set in several fragments the LAST one
# wins (e.g. dev.cfg re-enabling MAGIC_SYSRQ over security.cfg) - exactly like merge_config.
#   scripts/check-kernel-config.sh [prod|dev]
set -uo pipefail
. "$(dirname "$0")/lib.sh"
V=${1:-prod}
CFG="$WORK/output-$V/build/linux-6.12.47/.config"
FR="$REPO/br2-external/board/edgesight/linux"
frags="base virtio fs net security ml boot"; [ "$V" = dev ] && frags="$frags dev"
declare -A want from
order=()
for f in $frags; do
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*) opt=${line%%=*}; val=${line#*=} ;;
            "# CONFIG_"*" is not set") opt=${line#\# }; opt=${opt%% *}; val=n ;;
            *) continue ;;
        esac
        [ -z "${want[$opt]+x}" ] && order+=("$opt")
        want[$opt]=$val; from[$opt]=$f
    done < "$FR/$f.cfg"
done
bad=0
for opt in "${order[@]}"; do
    have=$(grep -E "^$opt=" "$CFG" | cut -d= -f2-)
    [ -z "$have" ] && have=n
    if [ "${want[$opt]}" != "$have" ]; then
        printf '  %-12s %-45s want=%-8s got=%s\n' "${from[$opt]}.cfg" "$opt" "${want[$opt]}" "$have"
        bad=$((bad+1))
    fi
done
echo "kernel config: $(( ${#order[@]} - bad ))/${#order[@]} fragment options applied as requested"
echo "  enabled options (=y): $(grep -c '=y$' "$CFG")   modules (=m): $(grep -c '=m$' "$CFG")"
exit $bad
