#!/usr/bin/env bash
# 从零构建可导入阿里云 ECS 的 Debian 云镜像（debootstrap + 最小化裁剪 + BIOS/UEFI 双引导）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

DEBIAN_RELEASE="${DEBIAN_RELEASE:?需要设置 DEBIAN_RELEASE（trixie/bookworm/bullseye/buster）}"
BOOT_MODE="${BOOT_MODE:-both}"
DISK_SIZE="${DISK_SIZE:-1G}"
ESP_SIZE="${ESP_SIZE:-64M}"
INITRAMFS_MODULES="${INITRAMFS_MODULES:-most}"
NODOC="${NODOC:-1}"
DEFAULT_USER="${DEFAULT_USER:-debian}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-${PWD}/dist}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/tmp/build-ssh-pubkey}"
SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE:-/tmp/build-password}"

case "${BOOT_MODE}" in
  both|bios|uefi) ;;
  *) die "boot_mode 只能是 both / bios / uefi，当前为 ${BOOT_MODE}" ;;
esac

resolve_release "${DEBIAN_RELEASE}"
case "${BOOT_MODE}" in
  both) BOOT_LABEL=bios-uefi ;;
  *)    BOOT_LABEL="${BOOT_MODE}" ;;
esac

require_root
for c in debootstrap losetup qemu-img sgdisk mkfs.ext4 mkfs.vfat blkid chroot curl dpkg find grep; do
  require_cmd "${c}"
done

# 防护：CRLF 换行会让 guest 内的脚本解析失败（例如 set -o pipefail 变成非法选项名），
# 在 Windows 上本地编辑过脚本时很容易踩到。
for f in "${SCRIPT_DIR}/guest-setup.sh" "${SCRIPT_DIR}/guest-finalize.sh" "${SCRIPT_DIR}/guest-grub.sh"; do
  assert_file "${f}"
  if grep -qU $'\r' "${f}" 2>/dev/null; then
    die "脚本 ${f} 含 CRLF 换行，在 guest 内会解析失败，请先转成 LF（dos2unix 或 sed -i 's/\\r$//'）"
  fi
done

ensure_debootstrap_suite "${SUITE}"
install_latest_archive_keyring

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
DISK_RAW="${WORK_DIR}/debian-${SUITE}-${BOOT_LABEL}.raw"
ROOTFS="${WORK_DIR}/rootfs"
LOOP=""

log "目标：Debian ${DEB_NUM} (${SUITE})｜引导=${BOOT_MODE}｜磁盘=${DISK_SIZE}｜ESP=${ESP_SIZE}"

cleanup() {
  set +e
  umount -R "${ROOTFS}/dev" 2>/dev/null
  umount -R "${ROOTFS}/sys" 2>/dev/null
  umount "${ROOTFS}/proc" 2>/dev/null
  umount "${ROOTFS}/boot/efi" 2>/dev/null
  umount "${ROOTFS}" 2>/dev/null
  [ -n "${LOOP}" ] && losetup -d "${LOOP}" 2>/dev/null
  return 0
}

log "创建 ${DISK_SIZE} 磁盘镜像"
rm -f "${DISK_RAW}"
qemu-img create -f raw "${DISK_RAW}" "${DISK_SIZE}" >/dev/null

LOOP="$(losetup --show -P -f "${DISK_RAW}")"
trap cleanup EXIT

log "分区：p1 bios_grub(EF02) / p2 ESP(EF00, ${ESP_SIZE}) / p3 root"
sgdisk --zap-all "${LOOP}" >/dev/null
sgdisk -n 1:2048:+2048 -t 1:ef02 -c 1:"BIOS boot" "${LOOP}" >/dev/null
sgdisk -n 2:0:"+${ESP_SIZE}" -t 2:ef00 -c 2:"EFI System" "${LOOP}" >/dev/null
sgdisk -n 3:0:0 -t 3:8300 -c 3:"root" "${LOOP}" >/dev/null

# 重新挂载一次，确保内核读到新的分区表
losetup -d "${LOOP}"
LOOP="$(losetup --show -P -f "${DISK_RAW}")"
ROOT_PART="${LOOP}p3"
ESP_PART="${LOOP}p2"

mkfs.ext4 -F -q -m 0 -L root "${ROOT_PART}"
mkfs.vfat -F 32 -n EFI "${ESP_PART}" >/dev/null
ROOT_UUID="$(blkid -s UUID -o value "${ROOT_PART}")"
ESP_UUID="$(blkid -s UUID -o value "${ESP_PART}")"
[ -n "${ROOT_UUID}" ] || die "无法获取根分区 UUID"
[ -n "${ESP_UUID}" ] || die "无法获取 ESP UUID"

reset_rootfs() {
  umount "${ROOTFS}/boot/efi" 2>/dev/null || true
  umount "${ROOTFS}" 2>/dev/null || true
  rm -rf "${ROOTFS}"
  mkdir -p "${ROOTFS}"
  mount "${ROOT_PART}" "${ROOTFS}"
  mkdir -p "${ROOTFS}/boot/efi"
  mount "${ESP_PART}" "${ROOTFS}/boot/efi"
}
reset_rootfs

KEYRING_ARGS=()
[ -f /usr/share/keyrings/debian-archive-keyring.gpg ] \
  && KEYRING_ARGS=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)

bootstrapped=0
for cand in ${CANDIDATES}; do
  main="${cand%%|*}"
  log "debootstrap ${SUITE} <- ${main}"
  if debootstrap --arch=amd64 --variant=minbase --components=main \
      "${KEYRING_ARGS[@]}" "${SUITE}" "${ROOTFS}" "${main}"; then
    bootstrapped=1
    break
  fi
  warn "debootstrap 失败，换下一个候选源"
  reset_rootfs
done
[ "${bootstrapped}" = "1" ] || die "debootstrap 在所有候选源上都失败了"

# ---------- 进入 chroot 完成配置 ----------
log "挂载伪文件系统"
mount -t proc proc "${ROOTFS}/proc"
mount --rbind /sys "${ROOTFS}/sys"
mount --make-rslave "${ROOTFS}/sys"
mount --rbind /dev "${ROOTFS}/dev"
mount --make-rslave "${ROOTFS}/dev"

PUBKEY_IN_IMAGE=/tmp/build-ssh-pubkey
PW_IN_IMAGE=/tmp/build-password
install -m 0755 "${SCRIPT_DIR}/guest-setup.sh"    "${ROOTFS}/tmp/guest-setup.sh"
install -m 0755 "${SCRIPT_DIR}/guest-finalize.sh" "${ROOTFS}/tmp/guest-finalize.sh"
install -m 0755 "${SCRIPT_DIR}/guest-grub.sh"     "${ROOTFS}/tmp/guest-grub.sh"

: > "${ROOTFS}${PUBKEY_IN_IMAGE}"
if [ -s "${SSH_PUBKEY_FILE}" ]; then
  cp "${SSH_PUBKEY_FILE}" "${ROOTFS}${PUBKEY_IN_IMAGE}"
  chmod 600 "${ROOTFS}${PUBKEY_IN_IMAGE}"
else
  warn "未提供 SSH 公钥：镜像内不含任何 authorized_keys"
fi
: > "${ROOTFS}${PW_IN_IMAGE}"
if [ -s "${SSH_PASSWORD_FILE}" ]; then
  cp "${SSH_PASSWORD_FILE}" "${ROOTFS}${PW_IN_IMAGE}"
  chmod 600 "${ROOTFS}${PW_IN_IMAGE}"
fi

{
  printf 'DEB_NUM=%q\n'          "${DEB_NUM}"
  printf 'SUITE=%q\n'            "${SUITE}"
  printf 'SEC_SUITE=%q\n'        "${SEC_SUITE}"
  printf 'EOL=%q\n'              "${EOL}"
  printf 'CANDIDATES=%q\n'       "${CANDIDATES}"
  printf 'BOOT_MODE=%q\n'        "${BOOT_MODE}"
  printf 'DISK_DEV=%q\n'         "${LOOP}"
  printf 'ROOT_UUID=%q\n'        "${ROOT_UUID}"
  printf 'ESP_UUID=%q\n'         "${ESP_UUID}"
  printf 'DEFAULT_USER=%q\n'     "${DEFAULT_USER}"
  printf 'TIMEZONE=%q\n'         "${TIMEZONE}"
  printf 'INITRAMFS_MODULES=%q\n' "${INITRAMFS_MODULES}"
  printf 'NODOC=%q\n'            "${NODOC}"
  printf 'PUBKEY_FILE=%q\n'      "${PUBKEY_IN_IMAGE}"
  printf 'PW_FILE=%q\n'          "${PW_IN_IMAGE}"
} > "${ROOTFS}/tmp/build-params.sh"

log "在 chroot 内安装并配置系统（这一步最慢，请耐心等待）"
chroot "${ROOTFS}" /bin/bash /tmp/guest-setup.sh

# ---------- 卸载前断言 ----------
IMAGE_VERSION="$(cat "${ROOTFS}/etc/debian_version" 2>/dev/null || true)"
[ -n "${IMAGE_VERSION}" ] || die "无法读取 /etc/debian_version"
USED_PCT="$(df -P "${ROOTFS}" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
log "镜像内 Debian 版本：${IMAGE_VERSION}｜根分区占用：${USED_PCT}%"
[ "${USED_PCT}" -lt 95 ] || die "根分区占用 ${USED_PCT}%，空间不足，无法保证首启扩容"

GRUB_CFG="${ROOTFS}/boot/grub/grub.cfg"
assert_file "${GRUB_CFG}"
grep -qE '^[[:space:]]*linux' "${GRUB_CFG}" || die "断言失败：grub.cfg 中没有内核启动项"
grep -q 'root=UUID=' "${GRUB_CFG}" || die "断言失败：grub.cfg 的 root= 不是 UUID（chroot 里 grub-probe 会解析失败）"
if grep -qE 'root=/dev/(loop|sd|vd|hd)' "${GRUB_CFG}"; then
  die "断言失败：grub.cfg 里写入了构建机的设备名，导入云平台后会找不到根设备"
fi
ls "${ROOTFS}"/boot/vmlinuz-*    >/dev/null 2>&1 || die "断言失败：缺少内核镜像"
ls "${ROOTFS}"/boot/initrd.img-* >/dev/null 2>&1 || die "断言失败：缺少 initramfs"
assert_file "${ROOTFS}/etc/ssh/sshd_config"
[ -s "${ROOTFS}/etc/network/interfaces" ] || die "断言失败：缺少 /etc/network/interfaces"
[ -e "${ROOTFS}/etc/cloud/cloud.cfg.d/99-cloud-build.cfg" ] || die "断言失败：缺少 cloud-init 配置"
[ ! -s "${ROOTFS}/etc/machine-id" ] || die "断言失败：/etc/machine-id 未清空"
case "${BOOT_MODE}" in
  uefi|both)
    assert_file "${ROOTFS}/boot/efi/EFI/BOOT/BOOTX64.EFI"
    assert_file "${ROOTFS}/boot/efi/EFI/debian/grubx64.efi"
    ;;
esac

log "回收已删除的数据块（决定最终镜像大小）"
trim_fs "${ROOTFS}"
trim_fs "${ROOTFS}/boot/efi"

log "卸载镜像"
cleanup
trap - EXIT

# ---------- 镜像文件层面的断言 + 压缩（独立脚本，便于单独调试） ----------
IMAGE_VERSION="${IMAGE_VERSION}" \
  bash "${SCRIPT_DIR}/finalize-image.sh" "${DISK_RAW}" "${BOOT_MODE}" "${OUTPUT_DIR}"
