#!/bin/bash

me="$(basename $0)"

cred='\033[1;31m'
cgrn='\033[1;32m'
cend='\033[0m'

HEXXEN_URL="https://github.com/Hexxeh/rpi-firmware/raw"
RASPI_URL="https://github.com/raspberrypi/linux/archive"

HEXXEH_COMMIT=
DEST_DIR="/tmp"
WORK_DIR="/tmp"

LOCALVERSION=+
CONFIG_MODE="module"
DO_LINKS="true"
DO_V6="true"
DO_V7="true"

CROSS_COMPILE_TOOLCHAIN=arm-linux-gnueabihf-
MAKE_CROSS_COMPILE_ARGS=

info() {
  printf "${cgrn}$1${cend}\n"
}

die() {
  [[ $1 ]] && printf "${cred}ERROR: $1${cend}\n" >&2
  [[ $2 ]] && printf "$2\n"
  exit 1
}

usage() {
  echo -e "Usage: $me [OPTIONS] HASH
Download and prepare Raspberry Pi kernel sources for building out of kernel modules.

Mandatory arguments:
  HASH   specify the Hexxeh commit hash of the kernel release to be downloaded

Optional arguments:
  -d, --directory=DIR          store the sources in DIR, defaults to '/tmp'
  -w, --working-directory=DIR  use DIR as working directory, defaults to '/tmp'
  -L, --local-version=VER      set make variable LOCALVERISON to VER, defaults to '+'
  -E, --extra-version=VER      set make variable EXTRAVERSION to VER
  -r, --release=VER            download release VER only, one of: 'v6', 'v7'
  -c, --config=MODE            if MODE='module': get .config file from configs.ko module,
                               if MODE='proc': get .config file from proc /proc/config.gz,
                               if MODE='skip': skip getting .config file,
                               defaults to 'module'
  -n, --no-links               skip making symbolic '/build' links
      --help                   display this help and exit
"
}

USAGE_HINT="Type '$me --help' to get usage information."

## @brief      Downloads kernel sources and appends release names to UNAME_R
## @param[out] UNAME_R Array holding the release names
get_sources() {
  # Get the Raspberrypi corrsponding commit hash
  RASPI_COMMIT=$(wget -nv -O - ${HEXXEN_URL}/${HEXXEH_COMMIT}/git_hash)
  if [[ ! ${RASPI_COMMIT} =~ [0-9a-f]{40} ]]; then
    die "Can't find Raspberry Pi commit hash!"
  fi
  info "raspberrypi/linux commit is ${RASPI_COMMIT}"

  # Get the kernel release version
  for v in "" "7"; do
    local release
    release=$(wget -nv -O - ${HEXXEN_URL}/${HEXXEH_COMMIT}/uname_string$v \
      | sed -r '/.*([1-9]{1}\.[1-9]{1,2}\.[1-9]{1,2}.*\+).*/{s//\1/;h};${x;/./{x;q0};x;q1}')
    if [ $? -ne 0 ]; then
      release="rpi-linux"
      if [ $v == "7" ]; then
        release="${release}-v7"
      fi
    fi
    UNAME_R+=(${release})
  done

  info "Release names are ${UNAME_R[0]} and ${UNAME_R[1]}"

  # Get kernel sources
  info "Downloading kernel sources to $(pwd) ..."
  wget -nv --show-progress -O rpi-linux.tar.gz \
      ${RASPI_URL}/${RASPI_COMMIT}.tar.gz
}

## @brief      Creates the kernel sources directory
## @param[in]  $1 Relase name
## @param[in]  DEST_DIR The path prefix
## @param[in]  DO_LINKS If 'true', creates the 'build' link
## @param[out] SRC_DIR Kernel sources directory path
## @param[out] MOD_DIR Kernel modules directory path
make_dirs() {
  local uname_r=$1
  # Make directories and links
  SRC_DIR="${DEST_DIR}/usr/src/${uname_r}"
  MOD_DIR="${DEST_DIR}/lib/modules/${uname_r}"
  mkdir -vp ${SRC_DIR}
  if [ ${DO_LINKS} = "true" ]; then
    mkdir -vp ${MOD_DIR}
    ln -svfn ${SRC_DIR} ${MOD_DIR}/build
  fi
}

## @brief      Extracts sources to the kernel sources directory
## @param[in]  $1 Relase name
## @param[in]  SRC_DIR Kernel sources directory path
extract_sources() {
  local uname_r=$1
  # Extract the sources
  info "Extracting ${uname_r} kernel sources to ${SRC_DIR} ..."
  if [[ -x "$(command -v pv)" ]]; then
      pv rpi-linux.tar.gz | bsdtar --strip-components=1 -xf - -C ${SRC_DIR}
  else
      bsdtar --strip-components=1 -xvf rpi-linux.tar.gz -C ${SRC_DIR}
  fi
  [[ $? -eq 0 ]] || die "Extracting kernel sources failed!"
}

## @brief      Creates the kernel .config file
## @param[in]  $1 Relase name
## @param[in]  CONFIG_MODE See --config
## @param[in]  SRC_DIR Kernel sources directory path
get_config() {
  local uname_r=$1
  # Get .config files
  case "${CONFIG_MODE}" in
    "module")
      info "Extracting .config file from 'configs.ko'"
      wget -nv --show-progress -O configs.ko \
          ${HEXXEN_URL}/${HEXXEH_COMMIT}/modules/${uname_r}/kernel/kernel/configs.ko
      ${SRC_DIR}/scripts/extract-ikconfig configs.ko  > ${SRC_DIR}/.config
      ;;
    "proc")
      info "Extracting .config file from '/proc/config.gz'"
      zcat /proc/config.gz > ${SRC_DIR}/.config
      ;;
  esac
}

## @brief      Downloads the Module.symvers file
## @param[in]  $1 Relase name
## @param[in]  SRC_DIR Kernel sources directory path
get_symvers() {
  local uname_r=$1
  local suffix
  [[ ${uname_r} =~ -v7 ]] && suffix="7"

  # Get Module.symvers files
  info "Downloading Module.symvers file for kernel ${uname_r}"
  wget -nv --show-progress -O ${SRC_DIR}/Module.symvers \
      ${HEXXEN_URL}/${HEXXEH_COMMIT}/Module${suffix}.symvers
}

## @brief      Prepares the sources for building kernel modules
## @param[in]  $1 Relase name
## @param[in]  SRC_DIR Kernel sources directory path
prepare_sources() {
  local uname_r=$1
  # Prepare modules
  info "Preparing ${uname_r} modules ..."
  make -C ${SRC_DIR} \
      LOCALVERSION=${LOCALVERSION} EXTRAVERSION=${EXTRAVERSION} \
      ${MAKE_CROSS_COMPILE_ARGS} modules_prepare
  [[ $? -eq 0 ]] || die "make modules_prepare failed!"
  info "\nDone, you can now build kernel modules"
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Parse command line options
OPTIONS=d::,w::,L::,E::,r:,c:,n,h
LONG_OPTIONS=directory:,working-directory:,local-version:,extra-version:,release:,config:,no-links
args=$(getopt --name "$me" -o ${OPTIONS} -l ${LONG_OPTIONS},help -- "$@")
[[ $? -eq 0 ]] || die "Wrong options." "${USAGE_HINT}"
eval set -- $args

while [ $# -gt 0 ]; do
  case "$1" in
    -d | --directory)          DEST_DIR="$2";     shift 2 ;;
    -w | --working-directory)  WORK_DIR="$2";     shift 2 ;;
    -L | --local-version)      LOCALVERSION="$2"; shift 2 ;;
    -E | --extra-version)      EXTRAVERSION="$2"; shift 2 ;;
    -r | --release)            DO_RELEASE="$2";   shift 2 ;;
    -c | --config)             CONFIG_MODE="$2";  shift 2 ;;
    -n | --no-links)           DO_LINKS="false";  shift ;;
    -h | --help)               usage; exit 0 ;;
    --)                        shift; break ;;
  esac
done

HEXXEH_COMMIT=${@:$OPTIND:1}

if [[ ! ${HEXXEH_COMMIT} ]]; then
  die "Can't proceed without Hexxeh commit hash." "${USAGE_HINT}"
fi

if [[ ! -x "$(command -v bsdtar)" ]]; then
  die "Could not find required program 'bsdtar'. Exiting..."
fi

if [ -n "${DO_RELEASE}" ]; then
  case "${DO_RELEASE}" in
    "v7") DO_V6="false" ;;
    "v6") DO_V7="false" ;;
       *) die "Invalid release." "${USAGE_HINT}"
  esac
fi

case "${CONFIG_MODE}" in
  "module") ;;
  "proc")   ;;
  "skip")   ;;
  *)        die "Invalid config mode." "${USAGE_HINT}"
esac

# Check if we need to cross compile
host_uname_m=$(uname -m)
if [[ ! ${host_uname_m} =~ ^arm(v[6-7]l|hf)$ ]]; then
  info "Host machine is ${host_uname_m}, setting up cross-compile toolchain"
  if [[ ! -x "$(command -v ${CROSS_COMPILE_TOOLCHAIN}gcc)" ]]; then
    die "Could not find '${CROSS_COMPILE_TOOLCHAIN}gcc', Exiting..."
  fi
  MAKE_CROSS_COMPILE_ARGS="ARCH=arm CROSS_COMPILE=${CROSS_COMPILE_TOOLCHAIN}"
fi

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Main
cd ${WORK_DIR}
get_sources


for r in ${UNAME_R[@]}; do
  if [[ $r =~ -v7 ]]; then
    [[ ${DO_V7} = "true" ]] || continue
  else
    [[ ${DO_V6} = "true" ]] || continue
  fi
  make_dirs       $r
  extract_sources $r
  get_config      $r
  get_symvers     $r
  prepare_sources $r
done

# vim: ts=2 sw=2 et
