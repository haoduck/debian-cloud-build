# Debian for Alibaba Cloud (ECS)

面向阿里云 ECS 的 **Debian 自定义镜像**构建项目。与姊妹项目 [alpine-cloud-build](https://github.com/haoduck/alpine-cloud-build)
思路一致（产出可直接导入的 `qcow2`），但实现方式不同：Alpine 版是「下载官方镜像再改」，
本项目是 **debootstrap 从零构建**——因为要同时满足「体积尽量小」「能跑在 1GB 系统盘」
「覆盖 Debian 10/11/12/13」，官方镜像改不动（虚拟盘 2~3GiB、ESP 固定占 512MiB）。

## 特性

| 项目 | 说明 |
|---|---|
| 支持版本 | Debian **10 (buster) / 11 (bullseye) / 12 (bookworm) / 13 (trixie)**，可一次全出 |
| 镜像体积 | 实测 Debian 13 双引导版 **约 153 MB**（官方 genericcloud 是 326 MB） |
| 磁盘占用 | 虚拟盘默认 **1 GiB**，根分区实际占用约 327 MB，**可跑在 1GB 系统盘上** |
| 引导方式 | 默认 **BIOS + UEFI 双引导**（GPT：bios_grub + ESP + root），也可只出单一模式 |
| 初始化 | 内置 cloud-init（含阿里云 datasource），支持密钥对注入、主机名、首启自动扩容 |
| 软件源 | 全部切换为阿里云镜像源（含 EOL 版本的 archive 源） |
| 时区 | `Asia/Shanghai`，chrony 使用 `ntp.aliyun.com` |

## 使用说明（阿里云）

1. 从 Releases 下载镜像，文件名形如 `debian-custom-<版本>-<引导标签>.qcow2`，
   例如 `debian-custom-13.7-bios-uefi.qcow2`
2. 在阿里云导入自定义镜像（镜像格式选 **QCOW2**）：
   - 默认产出的镜像 **BIOS 和 UEFI 都能启动**，「启动模式」选哪个都行
   - 如果构建时选了单一模式（`boot_mode=bios` / `uefi`），导入时「启动模式」必须与之一致
3. 创建 ECS 实例：
   - 可绑定 SSH 密钥对（镜像内已内置公钥，非必需；cloud-init 会把绑定的公钥追加进去）
   - **系统盘建议 ≥ 20 GiB**：阿里云控制台一般选不到 1 GiB 的系统盘。镜像虚拟盘是 1 GiB，
     实例系统盘更大完全没问题——cloud-init 首启会自动 `growpart` + `resize2fs` 扩到整盘
   - 登录用户：`debian`（可 sudo 免密）或 `root`
4. 首次登录：

   ```bash
   ssh -i <你的私钥> debian@<ECS公网IP>
   sudo -i
   # 或直接用 root
   ssh -i <你的私钥> root@<ECS公网IP>
   ```

## 构建镜像（GitHub Actions）

镜像由 `.github/workflows/build-debian-image.yml` 构建，触发方式二选一：

- 推送 `v*` 形式的 tag：
  ```bash
  git tag v1.0.0 && git push origin v1.0.0
  ```
- 在仓库 Actions 页面选择 `Build Debian Cloud Image` → **Run workflow** 手动触发：

| 输入项 | 说明 |
|---|---|
| `debian_release` | `all`（默认，10/11/12/13 全出）/ `trixie` / `bookworm` / `bullseye` / `buster` |
| `boot_mode` | `both`（默认，BIOS+UEFI）/ `bios` / `uefi` |
| `ssh_pubkey` | 注入镜像的 SSH 公钥（`root` 与 `debian` 用户都写入）。填 `none` 则不注入 |
| `password` | 同时为 `root` 与 `debian` 设置的登录密码，留空则不设密码 |
| `disk_size` | 镜像虚拟磁盘大小，默认 `1G` |
| `release_tag` | 要发布的 release tag，留空则用 `manual-<run number>` |

构建完成后：

- Release tag 带引导方式后缀：`<tag>-bios-uefi` / `<tag>-bios` / `<tag>-uefi`
- 镜像文件名带具体版本号与引导标签：`debian-custom-13.7-bios-uefi.qcow2`
  （版本号取自镜像内的 `/etc/debian_version`）
- 同时作为 workflow artifact 保留 14 天


## 本地构建

需要 Linux（root 权限 + loop 设备）以及 `debootstrap`、`qemu-utils`、`gdisk`、
`dosfstools`、`e2fsprogs`、`parted`、`xz-utils`：

```bash
sudo apt-get install -y debootstrap debian-archive-keyring gdisk parted \
  dosfstools e2fsprogs util-linux qemu-utils xz-utils curl

# 不注入公钥/密码时，先创建两个空文件（脚本按文件读取，避免密码出现在命令行里）
: > /tmp/build-ssh-pubkey
: > /tmp/build-password

sudo env DEBIAN_RELEASE=trixie BOOT_MODE=both DISK_SIZE=1G bash scripts/build-image.sh
# 产物：dist/debian-custom-<版本>-<引导标签>.qcow2
```

可用的环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DEBIAN_RELEASE` | 必填 | `trixie` / `bookworm` / `bullseye` / `buster` |
| `BOOT_MODE` | `both` | `both` / `bios` / `uefi` |
| `DISK_SIZE` | `1G` | 镜像虚拟磁盘大小 |
| `ESP_SIZE` | `64M` | EFI 系统分区大小（官方镜像是 512M，这里刻意压到 64M） |
| `INITRAMFS_MODULES` | `most` | 改成 `dep` 能再省十几 MB，但个别虚拟化平台可能起不来 |
| `NODOC` | `1` | 删除文档/手册/locale/i18n，只保留各包 `copyright` |
| `DEFAULT_USER` | `debian` | 默认普通用户 |
| `TIMEZONE` | `Asia/Shanghai` | 时区 |
| `SSH_PUBKEY_FILE` | `/tmp/build-ssh-pubkey` | 要注入的公钥文件（空文件 = 不注入） |
| `SSH_PASSWORD_FILE` | `/tmp/build-password` | 要设置的密码文件（空文件 = 不设密码） |
| `WORK_DIR` / `OUTPUT_DIR` | `./work` / `./dist` | 工作目录 / 产物目录 |

## 目录结构

```
.github/workflows/build-debian-image.yml   # 流水线：矩阵构建多个版本 + 发布 Release
scripts/lib.sh                             # 版本/软件源映射表、日志、断言、fstrim 回收
scripts/build-image.sh                     # 建盘 → 分区 → debootstrap → chroot 配置 → 回收 → 压缩
scripts/guest-setup.sh                     # 在 chroot 内执行：装包 + 系统配置 + 引导程序
scripts/guest-finalize.sh                  # 在 chroot 内执行：启用服务 + 清理裁剪
scripts/finalize-image.sh                  # 镜像级断言 + 转 qcow2 压缩
```

## 镜像已做的定制

- 使用 `debootstrap --variant=minbase` 从零安装，只装必需组件
- 预装：`systemd`、`openssh-server`、`cloud-init`、`cloud-guest-utils`、`chrony`、
  `ifupdown` + `isc-dhcp-client`、`sudo`、`ca-certificates`、`tzdata`、`gdisk`/`fdisk`
  （后两者是 cloud-init 首启扩容所必需）
- 内核使用体积更小的 `linux-image-cloud-amd64`（缺失时自动回退 `linux-image-amd64`）
- 默认软件源切换为阿里云（EOL 版本自动使用 `debian-archive` 并关闭 `Valid-Until` 校验）
- cloud-init 已启用，datasource 顺序为 `Aliyun → ConfigDrive → NoCloud`，
  首启自动 `growpart` + 扩容根分区
- SSH：允许 root 登录与密码登录、禁止空密码、`UseDNS no`
- 网卡固定为 `eth0`（内核参数 `net.ifnames=0`），网络由 ifupdown 走 DHCP
- 控制台可用：内核参数带 `console=tty0 console=ttyS0,115200n8`（阿里云 VNC/串口能看到启动日志）
- 引导参数写入 `/etc/default/grub` 后 `update-grub`；BIOS 与 UEFI 共用一份 `grub.cfg`
- 首启重新生成 SSH host key（`ssh-host-keys.service`），避免所有实例共用同一份密钥
- 清空 `/etc/machine-id` 与 `/var/lib/cloud/*`，确保 cloud-init 在首启重新初始化
- 卸载前执行 `fstrim` 回收已删除的块（不做这一步镜像会大一倍以上）

## 镜像未包含内容

- 阿里云官方 Agent（云助手等）
- 额外业务软件栈（Docker / K8s / 监控等）
- `systemd-resolved` / `systemd-networkd`（网络交给 ifupdown，避免与 cloud-init 抢配置）

如有需要，请在实例初始化后自行安装。

---

## 常见问题

### 实例启动卡在 `Booting from Hard Disk...`

引导方式不匹配。这句提示是传统 BIOS（SeaBIOS）输出的，说明实例按 Legacy BIOS 启动，
但磁盘上没有 BIOS 引导程序。

默认的 `boot_mode=both` 镜像两种模式都支持，不会出现这个问题。看到这个提示说明用的是
单一模式的镜像、且导入时「启动模式」选错了——阿里云 `ImportImage` 的 `BootMode` 参数
**默认是 `BIOS`**，所以导入 `boot_mode=uefi` 的镜像时如果不手动改成 UEFI 就会被卡住。

解决办法：

- 用默认的 `both` 重新构建，导入时选哪个模式都能启动
- 或者重新导入，把「启动模式」改成与镜像一致（选 UEFI 需要实例规格族支持 UEFI 启动）

### 登录不上，提示没有可用的密钥

镜像内是否内置公钥取决于构建时的 `ssh_pubkey` 输入：

- 填了公钥 → `root` 与 `debian` 都可用对应私钥登录
- 填了 `none` → 镜像内不含任何公钥，必须在创建实例时绑定密钥对
  （cloud-init 会把它追加进 `authorized_keys`），或用控制台 VNC 登录
- 镜像默认不预设密码，只有在构建时填了 `password` 才有密码

### 系统盘没有自动扩容

cloud-init 首启会执行 `growpart` + `resize_rootfs`。若没生效，登录后手动执行：

```bash
sudo growpart /dev/vda 3 && sudo resize2fs /dev/vda3
```

（镜像内根分区固定是第 3 个分区：p1 是 bios_grub，p2 是 ESP。）

### 想进一步压缩镜像体积

- `INITRAMFS_MODULES=dep`：initramfs 只带必要驱动，能再省十几 MB
- `ESP_SIZE=32M`：ESP 用不到 64M（引导文件只有几 MB）
- 不需要 UEFI 时用 `boot_mode=bios`，可以省掉整个 ESP
- 手动移除 `dbus`、`nano`、`less` 等非必需包（需自行改 `guest-setup.sh` 的包列表）

### Debian 10 / 11 已停止支持

- **Debian 10 (buster)**：2024-06-30 结束 LTS，**无任何安全更新**
- **Debian 11 (bullseye)**：2026-08-31 结束 LTS，**无任何安全更新**

这两个版本只能用于兼容性测试或隔离环境，不建议对外提供服务。它们的软件源指向阿里云的
`debian-archive` 镜像（已冻结），因此也不会再收到更新。

### cloud-init 没有生效

在实例里检查：

```bash
sudo cloud-init status --long
sudo cat /var/log/cloud-init.log
sudo ls /etc/systemd/system/cloud-init.target.wants/
```

若 cloud-init 根本没跑，多半是导入的镜像不是本项目默认产物，或实例没有元数据服务可达
（阿里云内网需能访问 `100.100.100.200`）。

---

## 免责声明

本镜像为社区用途的自定义构建版本，请先在测试环境验证后再用于生产环境。
