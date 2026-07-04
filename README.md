# Arch Linux 自动化安装脚本 (`install.sh`)

## 概述

`install.sh` 是一个交互式 Arch Linux 自动化安装脚本，用于替代 `archinstall`，提供从磁盘分区、格式化、基础系统安装到系统配置的完整安装流程。

## 功能特性

### 安装模式

| 模式                            | 说明                                                   |
| ------------------------------- | ------------------------------------------------------ |
| **Clean Install（全新安装）**   | 擦除目标磁盘全部数据，全新创建所有分区并安装系统       |
| **Reinstall（重装保留 /home）** | 保留现有`/home` 分区数据，仅重建 boot、swap、root 分区 |

### 分区方案

- **分区表**: GPT
- **Boot 分区**: 3G（UEFI 下为 FAT32 EFI 分区；BIOS 下为 BIOS boot + `/boot`）
- **Swap 分区**: 用户可配置，默认 1G（位于磁盘末尾）；可设为 0 跳过
- **Root + Home**: btrfs 文件系统，分别使用 `@` 和 `@home` 子卷

#### 分区大小策略（全新安装）

1. **自动 2:7 比例**（默认）—— root:home = 2:7
2. **半手动**—— 指定 root 大小，home 占用剩余空间
3. **全手动**—— 分别指定 boot、swap、root、home 大小

### 文件系统

| 分区 | 文件系统 | 子卷/标签 |
| ---- | -------- | --------- |
| Boot | FAT32    | `EFI`     |
| Root | btrfs    | `@`       |
| Home | btrfs    | `@home`   |
| Swap | swap     | `SWAP`    |

### 引导加载程序

| 固件类型 | 可选引导程序                         |
| -------- | ------------------------------------ |
| UEFI     | `systemd-boot`（默认，推荐）/ `GRUB` |
| BIOS     | `GRUB`（唯一选项）                   |

### 安装的软件包

- **基础系统**: `base`, `base-devel`, `linux-zen`, `linux-zen-headers`, `linux-lts`, `linux-lts-headers`, `linux-firmware`
- **文件系统工具**: `dosfstools`, `btrfs-progs`
- **网络与蓝牙**: `networkmanager`, `bluez`, `bluez-utils`
- **打印**: `cups`, `cups-filters`, `ghostscript`
- **音频**: `pipewire`, `pipewire-pulse`, `wireplumber`, `alsa-utils`
- **引导程序**: `systemd-boot` 对应 `efibootmgr`；`GRUB` 对应 `grub`（+ `efibootmgr` for UEFI）

### 安装后配置

- **时区**：自动设为 `Asia/Shanghai`（无交互，在基础系统安装步骤内完成）
- **Locale**：自动配置 `en_US.UTF-8`（无交互，在基础系统安装步骤内完成）
- **主机名**：默认 `archlinux`（可自定义）
- **fstab**：自动生成（含 UUID，btrfs 子卷挂载）
- **引导加载程序**：systemd-boot（Zen 内核默认，LTS 备用）或 GRUB
- **系统服务**：NetworkManager、Bluetooth、CUPS、PipeWire
- **initramfs**：zen 和 lts 内核并行重建（含 btrfs 模块）
- **sudo**：wheel 组启用
- **root 密码**与**普通用户**创建

### 性能优化

- **分区格式化并行化**：boot、swap、root、home 四个分区同时格式化
- **initramfs 并行生成**：linux-zen 和 linux-lts 的 mkinitcpio 同时执行
- **pacman 并行下载**：自动启用 `ParallelDownloads = 5`
- **partprobe 优化**：使用 `udevadm settle` 替代固定 sleep 等待
- **镜像源冗余**：直接写入 12 个国内高可用镜像，无网络请求延迟

### 镜像源

不使用 reflector（无需网络测速），直接写入以下国内镜像到 `/etc/pacman.d/mirrorlist`：

| 镜像 | 机构 |
|------|------|
| mirrors.tuna.tsinghua.edu.cn | 清华 TUNA |
| mirrors.ustc.edu.cn | 中科大 |
| mirrors.aliyun.com | 阿里云 |
| mirrors.163.com | 网易 |
| mirrors.zju.edu.cn | 浙江大学 |
| mirrors.sjtug.sjtu.edu.cn | 上海交大 |
| mirrors.nju.edu.cn | 南京大学 |
| mirrors.hit.edu.cn | 哈工大 |
| mirrors.bfsu.edu.cn | 北外 |
| mirrors.neusoft.edu.cn | 东软 |
| mirrors.cqu.edu.cn | 重庆大学 |
| mirrors.xjtu.edu.cn | 西安交大 |

pacstrap 失败时自动重试最多 3 次（每次重试重新写入静态镜像列表）；3 次全部失败后自动调用 reflector 搜索更多国内镜像并再次尝试。

### 安全设计

- 必须以 root 权限运行
- 执行前检查所有必需命令是否可用
- **所有破坏性操作默认 `[y/N]`** —— 回车即取消
- 用户中断（Ctrl+C）时执行清理

## 依赖

运行此脚本前，请确保以下命令在 Arch Linux 安装环境中可用：

`lsblk`, `sgdisk`, `mkfs.fat`, `mkfs.btrfs`, `mkswap`, `parted`, `bc`, `btrfs`

## 使用方法

```bash
# 在 Arch Linux 安装 ISO 环境中，以 root 身份运行：
方法1:
curl -L -O  https://cutt.ly/ArchInstall
chmod +x ArchInstall
./ArchInstall
方法2:
pacman -Syu git
git clone https://github.com/kamidream/ArchInstall.git
cd ArchInstall
chmod +x install.sh
./install.sh
```

按交互提示依次完成：

1. 风险确认（`[y/N]`）
2. 选择目标磁盘 → 选择固件类型与引导加载程序
3. 选择安装模式
4. 确认分区布局
5. 安装基础系统（含时区、locale 自动配置）
6. 配置系统（主机名、引导程序、服务、用户密码等）

---

## ⚠️ 风险声明

**使用本脚本意味着您已充分了解并自愿承担所有风险。**

- 本脚本会对磁盘执行**不可逆的破坏性操作**（包括擦除分区表、格式化分区），可能导致数据永久丢失。
- 作者不承担因使用本脚本而导致的任何数据丢失、硬件损坏、系统无法启动或其他直接或间接损失的**任何责任**。
- 在运行本脚本之前，请务必备份所有重要数据。
- 请仔细阅读每一步的提示信息，确认无误后再继续。
- 本脚本仅在特定环境下测试过，不保证在所有硬件配置或 Arch Linux 版本中均能正常工作。

**使用即表示您同意：您对使用本脚本的一切后果负全部责任。**
