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

info() {
  printf "${cgrn}$1${cend}\n"
}

die() {
  [[ $1 ]] && printf "${cred}ERROR: $1${cend}\n" >&2
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

get_sources() {
  # Get the Raspberrypi corrsponding commit hash
  RASPI_COMMIT=$(curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/git_hash)
  [[ ${RASPI_COMMIT} =~ [0-9a-f]{40} ]] \
    || die "Can't find Raspberry Pi commit hash!"
  info "raspberrypi/linux commit is ${RASPI_COMMIT}"

  # Get the kernel release version
  for uname in "uname_string" "uname_string7"; do
    UNAME_R+=($(curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/${uname} \
      | sed -r 's/.*([1-9]{1}\.[1-9]{1,2}\.[1-9]{1,2}.*\+).*/\1/g'))
  done
  info "Release names are ${UNAME_R[0]} and ${UNAME_R[1]}"

  # Get kernel sources
  info "Downloading kernel sources..."
  curl -L ${RASPI_URL}/${RASPI_COMMIT}.tar.gz > rpi-linux.tar.gz

  for r in ${UNAME_R[@]}; do
    if [[ $r =~ -v7 ]]; then
      if [ ${DO_V7} = "true" ]; then
        SUFFIX="7"
      else
        continue
      fi
    else
      if [ ${DO_V6} = "true" ]; then
        SUFFIX=""
      else
        continue
      fi
    fi

    # Make directories and links
    SRC_DIR="${DEST_DIR}/usr/src/$r"
    MOD_DIR="${DEST_DIR}/lib/modules/$r"
    mkdir -p ${SRC_DIR}
    if [ ${DO_LINKS} = "true" ]; then
      mkdir -p ${MOD_DIR}
      ln -svf ${SRC_DIR}  ${MOD_DIR}/build
    fi

    # Get Module.symvers files
    curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/Module${SUFFIX}.symvers \
      > ${SRC_DIR}/Module.symvers

    # Extract the sources
    info "Extracting $r kernel sources..."
    tar --strip-components 1 -xf rpi-linux.tar.gz -C ${SRC_DIR}

    # Get .config files
    case "${CONFIG_MODE}" in
      "module")
        info "Extracting .config file from 'configs.ko'"
        curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/modules/${UNAME_R}/kernel/kernel/configs.ko \
          > configs.ko
        ${SRC_DIR}/scripts/extract-ikconfig configs.ko  > ${SRC_DIR}/.config
        ;;
      "proc")
        info "Extracting .config file from '/proc/config.gz'"
        zcat /proc/config.gz > ${SRC_DIR}/.config
        ;;
    esac

    # Prepare modules
    info "Preparing $r modules..."
    # Check if we need to cross compile
    if [[ $(uname -m) =~ ^arm(v[6-7]l|hf)$ ]]; then
      make -C ${SRC_DIR} \
        LOCALVERSION=${LOCALVERSION} EXTRAVERSION=${EXTRAVERSION} \
        modules_prepare
    else
      make -C ${SRC_DIR} \
        LOCALVERSION=${LOCALVERSION} EXTRAVERSION=${EXTRAVERSION} \
        ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- modules_prepare
    fi
    [ $? -eq 0 ] || die "make modules_prepare failed!"
  done

  info "\nDone, you can now build kernel modules"
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Parse command line options
OPTIONS=d:,w:,L:,E:,r:,c:,n
LONG_OPTIONS=directory:,working-directory:,local-version:,extra-version:,release:,config:,no-links
args=$(getopt --name "$me" -o ${OPTIONS} -l ${LONG_OPTIONS},help -- "$@")
[ $? -eq 0 ] || die "Wrong options. Type '$me --help' to get usage information."
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
         --help)               usage; exit 0 ;;
    --)                        shift; break ;;
  esac
done

HEXXEH_COMMIT=${@:$OPTIND:1}

[[ ${HEXXEH_COMMIT} ]] || die "Can't proceed without Hexxeh commit hash. \
Type '$me --help' to get usage information."

case "${DO_RELEASE}" in
  "v7") DO_V6="false" ;;
  "v6") DO_V7="false" ;;
     *) die "Invalid release. Type '$me --help' to get usage information."
esac

case "${CONFIG_MODE}" in
  "module") ;;
  "proc")   ;;
  "skip")   ;;
  *)        die "Invalid config mode. Type '$me --help' to get usage information."
esac

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Main
cd ${WORK_DIR}
get_sources

# vim: ts=2 sw=2 et
