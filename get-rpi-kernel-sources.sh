#!/bin/bash

me="$(basename $0)"

cred='\033[1;31m'
cgrn='\033[1;32m'
cend='\033[0m'

FIRMWARE_URL="https://github.com/raspberrypi/firmware/raw"
KERNEL_URL="https://github.com/raspberrypi/linux/archive"
PCP_URL="https://repo.picoreplayer.org/repo"

FIRMWARE_COMMIT=
DEST_DIR="/tmp"
WORK_DIR="/tmp"

LOCALVERSION=""
EXTRAVERSION="+rpt-rpi"
CONFIG_MODE="module"
DO_LINKS="true"

CROSS_COMPILE_TOOLCHAIN_32=arm-linux-gnueabihf-
CROSS_COMPILE_TOOLCHAIN_64=aarch64-linux-gnu-

# Global associative array for version->suffix mapping
declare -A UNAME_R_TO_SUFFIX

# Global array for kernel version strings
UNAME_R=()

info() { # <$1: info message>
  printf "${cgrn}$1${cend}\n"
}

die() { # [$1: error message] [$2: hint]
  [[ $1 ]] && printf "${cred}ERROR: $1${cend}\n" >&2
  [[ $2 ]] && printf "$2\n"
  exit 1
}

usage() {
  echo -e "Usage: $me [OPTIONS] HASH
Download and prepare Raspberry Pi kernel sources for building out of kernel modules.

Mandatory arguments:
  HASH   specify the firmware commit hash of the kernel release to be downloaded

Optional arguments:
  -d, --directory=DIR          store the sources in DIR, defaults to '/tmp'
  -w, --working-directory=DIR  use DIR as working directory, defaults to '/tmp'
  -L, --local-version=VER      set make variable LOCALVERISON to VER
  -E, --extra-version=VER      set make variable EXTRAVERSION to VER, defaults to '+rpt-rpi'
  -r, --release=VER            download release VER only, one of: 'v6', 'v7', 'v7l', 'v8' or 'v8-16k'
                               if not specified, all releases are downloaded
  -c, --config=MODE            if MODE='module': get .config file from configs.ko module,
                               if MODE='proc': get .config file from proc /proc/config.gz,
                               if MODE='skip': skip getting .config file,
                               defaults to 'module'
      --distro=NAME            download and prepare sources for distro NAME
      --pcp-core=VER           if distro is 'pcp', set core version to VER, eg. '9.x'
      --pcp-rt                 if distro is 'pcp', prepare sources for 'Realtime' version
  -n, --no-links               skip making symbolic '/build' links
  -h, --help                   display this help and exit

Dependencies:
  pv bsdtar bc flex bison libssl-dev

"
}

USAGE_HINT="Type '$me --help' to get usage information."

set_pcp_vars() { # <$1: Relase name>
  local uname_r=$1
  local pcp_core_version=${PCP_CORE_VERSION}
  local release=$(echo ${uname_r} | sed -r 's/[+-].*//')

  local armv
  local armv_suffix
  if [[ ${uname_r} =~ -v7 ]]; then
    armv="armv7"
    armv_suffix="_v7"
  else
    armv="armv6"
  fi

  local pcp_version
  local pcp_rt_suffix
  if [[ ${PCP_RT} = "true" ]]; then
    pcp_version="pcpAudioCore"
    pcp_rt_suffix="-rt"
  else
    pcp_version="pcpCore"
  fi

  PCP_UNAME_R=${release}-${pcp_version}${armv_suffix}${pcp_rt_suffix}

  PCP_URL_REFIX=${PCP_URL}
  PCP_URL_REFIX+="/$pcp_core_version/$armv/releases/RPi/src/kernel"
  PCP_URL_REFIX+="/${PCP_UNAME_R}_"
}

get_uname_string_suffix() { # <$1: Relase name>
  # Given a release name, returns the "uname_string_" file name suffix.
  # For example "7l" given "4.19.86-v7l+" or "_2712" given "6.12.36-v8-16k+".
  echo "${UNAME_R_TO_SUFFIX[$1]}" || die "Unknown release name: $1"
}

get_sources() {
  # Get the Raspberrypi corrsponding commit hash
  RASPI_COMMIT=$(wget -nv -O - ${FIRMWARE_URL}/${FIRMWARE_COMMIT}/extra/git_hash)
  RASPI_LINUX_ARCHIVE_NAME=${RASPI_COMMIT}.tar.gz

  if [[ ! ${RASPI_COMMIT} =~ [0-9a-f]{40} ]]; then
    die "Can't find Raspberry Pi commit hash!"
  fi
  info "raspberrypi/linux commit is ${RASPI_COMMIT}"

  # Get the kernel release version, populates global associative array
  for v in "" "7" "7l" "8" "_2712"; do
    version_string=$(wget -nv -O - ${FIRMWARE_URL}/${FIRMWARE_COMMIT}/extra/uname_string$v \
      | sed -r '/.*([1-9]{1}\.[0-9]{1,2}\.[0-9]{1,2}.*\+).*/{s//\1/;h};${x;/./{x;q0};x;q1}')
    if [[ -n "$version_string" ]]; then
      UNAME_R_TO_SUFFIX["$version_string"]="$v"  # Map version to suffix
      UNAME_R+=("$version_string")  # Keep compatibility with existing array
    fi
  done

  if [ ${#UNAME_R[@]} -eq 0 ]; then
    die "Can't find release version string!"
  else
    info "Found ${#UNAME_R[*]} versions:"
    for version in "${UNAME_R[@]}"; do
      local suffix=$(get_uname_string_suffix ${version})
      printf "  * %-5s -> %s\n" "$suffix" "$version"
    done
  fi

  # Get kernel sources
  info "Downloading kernel sources to $(pwd) ..."
  wget -nv --show-progress -nc ${KERNEL_URL}/${RASPI_LINUX_ARCHIVE_NAME}
}

make_dirs() { # <$1: Relase name>
  local uname_r=$1
  local suffix=$(get_uname_string_suffix ${uname_r})

  # Extract base version (e.g. 6.12.36-v7l+ -> 6.12.36)
  local base_version="${uname_r%%[-+]*}"

  # Create directory name: base_version + EXTRAVERSION + architecture suffix
  local dir_name="${base_version}${EXTRAVERSION}"
  case "${suffix}" in
    "")      dir_name="${dir_name}-v6" ;;
    "7")     dir_name="${dir_name}-v7" ;;
    "7l")    dir_name="${dir_name}-v7l" ;;
    "8")     dir_name="${dir_name}-v8" ;;
    "_2712") dir_name="${dir_name}-2712" ;;
    *) die "Unexpected release suffix: ${suffix}" ;;
  esac

  # Make directories and links
  SRC_DIR="${DEST_DIR}/usr/src/${dir_name}"
  MOD_DIR="${DEST_DIR}/lib/modules/${dir_name}"
  mkdir -vp ${SRC_DIR}
  if [ ${DO_LINKS} = "true" ]; then
    mkdir -vp ${MOD_DIR}
    ln -svfn ${SRC_DIR} ${MOD_DIR}/build
  fi
}

extract_sources() { # <$1: Relase name>
  local uname_r=$1
  local archive=${RASPI_LINUX_ARCHIVE_NAME}
  # Extract the sources
  info "Extracting ${uname_r} kernel sources to ${SRC_DIR} ..."
  if [[ -x "$(command -v pv)" ]]; then
      pv ${archive} | bsdtar --strip-components=1 -xkf - -C ${SRC_DIR}
  else
      bsdtar --strip-components=1 -xkvf ${archive} -C ${SRC_DIR}
  fi
  [[ $? -eq 0 ]] || die "Extracting kernel sources failed!"
}

get_config() { # <$1: Relase name>
  local uname_r=$1
  # Get .config files
  case "${DISTRO}" in
    "")
      case "${CONFIG_MODE}" in
        "module")
          info "Extracting .config file from the 'configs' module"
          local config_file="configs-${uname_r}.ko.xz"
          wget -nv --show-progress -O "$config_file"  \
              ${FIRMWARE_URL}/${FIRMWARE_COMMIT}/modules/${uname_r}/kernel/kernel/configs.ko.xz \
              || die "Downloading the 'configs' module failed!"
          ${SRC_DIR}/scripts/extract-ikconfig ${config_file}  > ${SRC_DIR}/.config \
              || die "Extracting .config file failed!"
          ;;
        "proc")
          info "Extracting .config file from '/proc/config.gz'"
          zcat /proc/config.gz > ${SRC_DIR}/.config
          ;;
      esac
      ;;
    "pcp")
      info "Downloading .config file for kernel ${uname_r}"
      wget -4 -nv --show-progress -O - ${PCP_URL_REFIX}.config.xz \
          | xzcat -v > ${SRC_DIR}/.config
      ;;
  esac
}

patch_config() { # <$1: Relase name>
  local uname_r=$1
  local suffix=$(get_uname_string_suffix ${uname_r})


  case "${suffix}" in
    "")      # For v6: "" -> "-v6"
      info "Patching .config for ${uname_r} to use -v6 suffix"
      sed -i -E 's/^(CONFIG_LOCALVERSION=)""$/\1"-v6"/' ${SRC_DIR}/.config
      ;;
    "_2712") # For _2712: "-v8-16k" -> "-2712"
      info "Patching .config for ${uname_r} to use -2712 suffix"
      sed -i -E 's/^(CONFIG_LOCALVERSION=)"-v8-16k"$/\1"-2712"/' ${SRC_DIR}/.config
      ;;
  esac
}

get_symvers() { # <$1: Relase name>
  local uname_r=$1
  # Get Module.symvers files
  info "Downloading Module.symvers file for kernel ${uname_r}"
  case "${DISTRO}" in
    "")
      local suffix=$(get_uname_string_suffix ${uname_r})
      wget -nv --show-progress -O ${SRC_DIR}/Module.symvers \
          ${FIRMWARE_URL}/${FIRMWARE_COMMIT}/extra/Module${suffix}.symvers
      ;;
    "pcp")
      wget -4 -nv --show-progress -O - ${PCP_URL_REFIX}Module.symvers.xz \
          | xzcat -v > ${SRC_DIR}/Module.symvers
      ;;
  esac
}

prepare_sources() { # <$1: Relase name>
  local uname_r=$1
  # Prepare modules
  info "Preparing ${uname_r} modules ..."

  # Set cross-compile args, if needed
  local cross_compile_args=""
  local suffix=$(get_uname_string_suffix ${uname_r})
  case "${suffix}" in
    ""|"7"|"7l")
      # 32-bit ARM (v6, v7, v7l)
      if [[ ! ${host_uname_m} =~ ^(arm(v[6-7]l|hf))$ ]]; then
        cross_compile_args="ARCH=arm CROSS_COMPILE=${CROSS_COMPILE_TOOLCHAIN_32}"
      fi
      ;;
    "8"|"_2712")
      # 64-bit ARM (v8, v8-16k/Pi5)
      if [[ ! ${host_uname_m} =~ ^(aarch64)$ ]]; then
        cross_compile_args="ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE_TOOLCHAIN_64}"
      fi
      ;;
    *)
      die "Unexpected release suffix: ${suffix}"
      ;;
  esac
  make -C ${SRC_DIR} \
      LOCALVERSION=${LOCALVERSION} EXTRAVERSION=${EXTRAVERSION} \
      ${cross_compile_args} modules_prepare
  [[ $? -eq 0 ]] || die "make modules_prepare failed!"
  info "\nDone, you can now build ${uname_r} kernel modules"
}

#------------------------------------------------------------------------------
# Parse command line options
#------------------------------------------------------------------------------
OPTIONS=d::,w::,L::,E::,r:,c:,n,h
LONG_OPTIONS=directory:,working-directory:,local-version:,extra-version:,\
release:,config:,no-links,distro:,pcp-core:,pcp-rt
args=$(getopt --name "$me" -o ${OPTIONS} -l ${LONG_OPTIONS},help -- "$@")
[[ $? -eq 0 ]] || die "Wrong options." "${USAGE_HINT}"
eval set -- $args

while [ $# -gt 0 ]; do
  case "$1" in
    -d | --directory)          DEST_DIR="$2";          shift 2 ;;
    -w | --working-directory)  WORK_DIR="$2";          shift 2 ;;
    -L | --local-version)      LOCALVERSION="$2";      shift 2 ;;
    -E | --extra-version)      EXTRAVERSION="$2";      shift 2 ;;
    -r | --release)            DO_RELEASE="$2";        shift 2 ;;
    -c | --config)             CONFIG_MODE="$2";       shift 2 ;;
         --distro)             DISTRO="$2";            shift 2 ;;
         --pcp-core)           PCP_CORE_VERSION="$2";  shift 2 ;;
         --pcp-rt)             PCP_RT="true";          shift ;;
    -n | --no-links)           DO_LINKS="false";       shift ;;
    -h | --help)               usage; exit 0 ;;
    --)                        shift; break ;;
  esac
done

FIRMWARE_COMMIT=${@:$OPTIND:1}

if [[ ! ${FIRMWARE_COMMIT} ]]; then
  die "Can't proceed without firmware commit hash." "${USAGE_HINT}"
fi

if [[ ! -x "$(command -v bsdtar)" ]]; then
  die "Could not find required program 'bsdtar'. Exiting..."
fi

if [ -n "${DO_RELEASE}" ]; then
  case "${DO_RELEASE}" in
    "v6"|"v7"|"v7l"|"v8"|"v8-16k") ;;
       *) die "Invalid release." "${USAGE_HINT}"
  esac
fi

case "${CONFIG_MODE}" in
  "module") ;;
  "proc")   ;;
  "skip")   ;;
  *)        die "Invalid config mode." "${USAGE_HINT}"
esac

case ${DISTRO} in
  "")       ;;
  "pcp")    [[ ${PCP_CORE_VERSION} ]] || die "Can't proceed without --pcp-core argument" ;;
  *)        die "Invalid distro mode." "${USAGE_HINT}"
esac

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
host_uname_m=$(uname -m)
info "Host machine is ${host_uname_m}"
cd ${WORK_DIR}
get_sources

for r in ${UNAME_R[@]}; do

  suffix=$(get_uname_string_suffix ${r})
  if [[ -n "${DO_RELEASE}" ]]; then
    case "${suffix}" in
      "")      [[ "${DO_RELEASE}" == "v6" ]]     || continue ;;
      "7")     [[ "${DO_RELEASE}" == "v7" ]]     || continue ;;
      "7l")    [[ "${DO_RELEASE}" == "v7l" ]]    || continue ;;
      "8")     [[ "${DO_RELEASE}" == "v8" ]]     || continue ;;
      "_2712") [[ "${DO_RELEASE}" == "v8-16k" ]] || continue ;;
      *) die "Unexpected release suffix: ${suffix}" ;;
    esac
  fi
  case ${DISTRO} in
    "")                       make_dirs $r             ;;
    "pcp") set_pcp_vars $r && make_dirs ${PCP_UNAME_R} ;;
  esac
  extract_sources $r
  get_config      $r
  patch_config    $r
  get_symvers     $r
  prepare_sources $r
done

# vim: ts=2 sw=2 et
