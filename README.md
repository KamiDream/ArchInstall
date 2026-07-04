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
- **Swap 分区**: 用户可配置，默认 4G（位于磁盘末尾）；可设为 0 跳过
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

- 时区设置（默认 `Asia/Shanghai`）
- Locale 配置（`en_US.UTF-8`）
- 主机名设置
- fstab 自动生成（含 UUID）
- 引导加载程序安装与配置（Zen 内核默认，LTS 备用）
- 系统服务启用：NetworkManager、Bluetooth、CUPS、PipeWire
- initramfs 重建（含 btrfs 模块）
- sudo 权限启用（wheel 组）
- root 密码设置
- 普通用户创建（wheel 组）

### 安全设计

- 必须以 root 权限运行
- 执行前检查所有必需命令是否可用
- 破坏性操作默认 `[y/N]` —— 回车即取消
- 用户中断（Ctrl+C）时执行清理

## 依赖

运行此脚本前，请确保以下命令在 Arch Linux 安装环境中可用：

`lsblk`, `sgdisk`, `mkfs.fat`, `mkfs.btrfs`, `mkswap`, `parted`, `bc`, `btrfs`, `reflector`

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
chmode +x install.sh
./install.sh
```

按交互提示依次完成：

1. 选择固件类型与引导加载程序
2. 选择目标磁盘
3. 选择安装模式
4. 确认分区布局
5. 安装基础系统
6. 配置系统（时区、主机名、引导程序、服务、用户等）

---

## ⚠️ 风险声明

**使用本脚本意味着您已充分了解并自愿承担所有风险。**

- 本脚本会对磁盘执行**不可逆的破坏性操作**（包括擦除分区表、格式化分区），可能导致数据永久丢失。
- 作者不承担因使用本脚本而导致的任何数据丢失、硬件损坏、系统无法启动或其他直接或间接损失的**任何责任**。
- 在运行本脚本之前，请务必备份所有重要数据。
- 请仔细阅读每一步的提示信息，确认无误后再继续。
- 本脚本仅在特定环境下测试过，不保证在所有硬件配置或 Arch Linux 版本中均能正常工作。

**使用即表示您同意：您对使用本脚本的一切后果负全部责任。**
