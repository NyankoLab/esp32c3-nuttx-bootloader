#!/usr/bin/env bash
#
#  Copyright (c) 2021 Espressif Systems (Shanghai) Co., Ltd.
#
# SPDX-License-Identifier: Apache-2.0
#

SCRIPT_ROOTDIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
MCUBOOT_ROOTDIR=$(realpath "${MCUBOOT_ROOTDIR:-${SCRIPT_ROOTDIR}/mcuboot}")
IDF_PATH="${IDF_PATH:-${MCUBOOT_ROOTDIR}/boot/espressif/hal/esp-idf}"

set -eo pipefail

supported_targets=("esp32c3")

usage() {
  echo ""
  echo "USAGE: ${SCRIPT_NAME} [-h] [-s] -c <chip> -f <config>"
  echo ""
  echo "Where:"
  echo "  -c <chip> Target chip (options: ${supported_targets[*]})"
  echo "  -f <config> Path to file containing configuration options"
  echo "  -s Setup environment"
  echo "  -h Show usage and terminate"
  echo ""
}

setup() {
  # Update MCUboot repository

  git -C "${SCRIPT_ROOTDIR}" submodule update --init mcuboot

  # Update MCUboot dependencies

  git -C "${MCUBOOT_ROOTDIR}" submodule update --init --recursive ext/mbedtls

  if [ "${IDF_PATH}" == "${MCUBOOT_ROOTDIR}/boot/espressif/hal/esp-idf" ]; then
    # Not using --recursive since MCUboot only requires the bootloader_support component from IDF

    git -C "${MCUBOOT_ROOTDIR}" submodule update --init --checkout boot/espressif/hal/esp-idf
  fi
}

build_mcuboot() {
  local target=${1}
  local config=${2}
  local build_dir=".build-${target}"
  local source_dir="boot/espressif"
  local output_dir="${SCRIPT_ROOTDIR}/out"
  local toolchain_file="tools/toolchain-${target}.cmake"
  local mcuboot_config
  local mcuboot_flashsize
  local mcuboot_flashmode
  local mcuboot_flashfreq
  local make_generator

  mcuboot_config=$(realpath "${config:-${SCRIPT_ROOTDIR}/mcuboot.conf}")

  # Try parsing Flash parameters from the mcuboot config file.
  # If not found, let's assume some commonplace values.

  mcuboot_flashsize=$(sed -n 's/^CONFIG_ESPTOOLPY_FLASHSIZE_\(.*\)MB=1/\1MB/p' "${mcuboot_config}")
  if [ -z "${mcuboot_flashsize}" ]; then
    mcuboot_flashsize="4MB"
  fi

  mcuboot_flashmode=$(sed -n 's/^CONFIG_ESPTOOLPY_FLASHMODE_\(.*\)=1/\L\1/p' "${mcuboot_config}")
  if [ -z "${mcuboot_flashmode}" ]; then
    mcuboot_flashmode="dio"
  fi

  mcuboot_flashfreq=$(sed -n 's/^CONFIG_ESPTOOLPY_FLASHFREQ_\(.*\)M=1/\1m/p' "${mcuboot_config}")
  if [ -z "${mcuboot_flashfreq}" ]; then
    mcuboot_flashfreq="40m"
  fi

  pushd "${SCRIPT_ROOTDIR}" &>/dev/null
  mkdir -p "${output_dir}" &>/dev/null

  # Build with Ninja if installed

  if command -v ninja &>/dev/null; then
    make_generator="-GNinja"
  fi

  # Build bootloader for selected target

  cd "${MCUBOOT_ROOTDIR}" &>/dev/null
  cmake -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}"  \
        -DMCUBOOT_TARGET="${target}"                \
        -DMCUBOOT_CONFIG_FILE="${mcuboot_config}"   \
        -DESP_HAL_PATH="${IDF_PATH}"                \
        -B "${build_dir}"                           \
        "${make_generator}"                         \
        "${source_dir}"
  cmake --build "${build_dir}"/
  esptool.py --chip "${target}" elf2image           \
        --flash_size "${mcuboot_flashsize}"         \
        --flash_mode "${mcuboot_flashmode}"         \
        --flash_freq "${mcuboot_flashfreq}"         \
        -o "${build_dir}"/mcuboot-"${target}".bin   \
        "${build_dir}"/mcuboot_"${target}".elf

  # Copy bootloader binary file to output directory

  cp "${build_dir}"/mcuboot-"${target}".bin "${output_dir}"/mcuboot-"${target}".bin &>/dev/null

  # Remove build directory

  rm -rf "${build_dir}" &>/dev/null

  popd &>/dev/null
}

while getopts ":hc:f:s" arg; do
  case "${arg}" in
    c)
      chip=${OPTARG}
      ;;
    f)
      config=${OPTARG}
      ;;
    s)
      setup
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ -z "${chip}" ]; then
  printf "ERROR: Missing target chip.\n"
  usage
  exit 1
fi

if [ -n "${config}" ] && [ ! -f "${config}" ]; then
  printf "ERROR: Configuration file %s not found.\n" "${config}"
  usage
  exit 1
fi

if [[ ! "${supported_targets[*]}" =~ ${chip} ]]; then
  printf "ERROR: Target \"%s\" is not supported!\n" "${chip}"
  usage
  exit 1
fi

build_mcuboot "${chip}" "${config}"
