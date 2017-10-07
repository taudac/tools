#!/bin/bash

me="$(basename $0)"

cred='\033[1;31m'
cgrn='\033[1;32m'
cend='\033[0m'

HEXXEN_URL="https://github.com/Hexxeh/rpi-firmware/raw"
RASPI_URL="https://github.com/raspberrypi/linux/archive"

HEXXEH_COMMIT=
DEST_DIR="/tmp"

info() {
  printf "${cgrn}$1${cend}\n"
}

die() {
  [[ $1 ]] && printf "${cred}ERROR: $1${cend}\n"
  exit 1
}

usage() {
  echo -e "Usage: $me -x=HASH [-d=DIR]
Download and prepare Raspberry Pi kernel sources for building out of kernel modules.

Mandatory arguments:
  -x, --hexxeh-commit=HASH  specify the Hexxeh commit hash of the kernel release to be downloaded

Optional arguments:
  -d, --directory=DIR       store the sources in DIR, defaults to '/tmp'
      --help                display this help and exit
"
}

get_sources() {
  # Get the Raspberrypi corrsponding commit hash
  RASPI_COMMIT=$(curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/git_hash)
  [[ ${RASPI_COMMIT} =~ [0-9a-f]{40} ]] || die "Can't find Raspberry Pi commit hash!"
  info "Raspberrypi commit is ${RASPI_COMMIT}"

  # Get the kernel release version
  UNAME_R=$(curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/uname_string   | sed -r 's/.*([1-9]{1}\.[1-9]{1,2}\.[1-9]{1,2}.*\+).*/\1/g')
  UNAME_R7=$(curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/uname_string7 | sed -r 's/.*([1-9]{1}\.[1-9]{1,2}\.[1-9]{1,2}.*\+).*/\1/g')
  info "Release names are ${UNAME_R} and ${UNAME_R7}"

  # Make directories
  SRC_DIR="${DEST_DIR}/usr/src/${UNAME_R}"
  SRC_DIR7="${DEST_DIR}/usr/src/${UNAME_R7}"
  MOD_DIR="${DEST_DIR}/lib/modules/${UNAME_R}"
  MOD_DIR7="${DEST_DIR}/lib/modules/${UNAME_R7}"
  mkdir -p ${SRC_DIR}
  mkdir -p ${SRC_DIR7}
  mkdir -p ${MOD_DIR}
  mkdir -p ${MOD_DIR7}

  # Get Module.symvers files
  curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/Module.symvers  > ${SRC_DIR}/Module.symvers
  curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/Module7.symvers > ${SRC_DIR7}/Module.symvers

  # Get kernel sources
  info "Downloading kernel sources..."
  curl -L ${RASPI_URL}/${RASPI_COMMIT}.tar.gz > rpi-linux.tar.gz
  info "Extracting kernel sources..."
  tar --strip-components 1 -xf rpi-linux.tar.gz -C ${SRC_DIR}
  tar --strip-components 1 -xf rpi-linux.tar.gz -C ${SRC_DIR7}

  # Get .config files
  info "Extracting .config files..."
  curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/modules/${UNAME_R}/kernel/kernel/configs.ko  > configs.ko
  curl -L ${HEXXEN_URL}/${HEXXEH_COMMIT}/modules/${UNAME_R7}/kernel/kernel/configs.ko > configs7.ko
  ${SRC_DIR}/scripts/extract-ikconfig  configs.ko  > ${SRC_DIR}/.config
  ${SRC_DIR7}/scripts/extract-ikconfig configs7.ko > ${SRC_DIR7}/.config

  # Prepare modules
  info "Preparing ${UNAME_R} modules..."
  make -C ${SRC_DIR}  ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION=+ modules_prepare
  info "Preparing ${UNAME_R7} modules..."
  make -C ${SRC_DIR7} ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION=+ modules_prepare

  # Make links
  ln -sv ${SRC_DIR}  ${MOD_DIR}/build
  ln -sv ${SRC_DIR7} ${MOD_DIR7}/build

  info "\nDone, you can now build kernel modules"
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Parse command line options
args=$(getopt --name "$me" -o x:,d: -l hexxeh-commit:,directory:,help -- "$@")
[ $? -eq 0 ] || die "Wrong options. Type '$me --help' to get usage information."
eval set -- $args

while [ $# -gt 0 ]; do
    case "$1" in
        -x | --hexxeh-commit) HEXXEH_COMMIT="$2"; shift ;;
        -d | --directory)     DEST_DIR="$2"; shift ;;
             --help)          usage; exit 0 ;;
        --)                   shift; break ;;
    esac
    shift
done

[[ ${HEXXEH_COMMIT} ]] || die "Can't proceed without Hexxeh commit hash. \
Type '$me --help' to get usage information."

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Main
cd /tmp
get_sources
