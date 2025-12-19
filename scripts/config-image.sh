#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..

mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_package="$(basename "$(find u-boot-"${BOARD}"_*.deb | sort | tail -n1)")"
    if [ ! -e "$uboot_package" ]; then
        echo 'Error: could not find the u-boot package'
        exit 1
    fi

    # 自动模糊匹配build目录的最新内核deb，只用本地，不拉云源
    linux_image_package="$(basename "$(find linux-image-*.deb | sort | tail -n1)")"
    linux_headers_package="$(basename "$(find linux-headers-*.deb | sort | tail -n1)")"
    linux_modules_package="$(basename "$(find linux-modules-*.deb | sort | tail -n1)")"
    linux_buildinfo_package="$(basename "$(find linux-buildinfo-*.deb | sort | tail -n1)")"
    linux_rockchip_headers_package="$(basename "$(find linux-rockchip-headers-*.deb | sort | tail -n1)")"

    for pkg in "$linux_image_package" "$linux_headers_package" "$linux_modules_package" "$linux_buildinfo_package" "$linux_rockchip_headers_package"; do
        if [ ! -e "$pkg" ]; then
            echo "Error: could not find the required package $pkg"
            exit 1
        fi
    done
fi

setup_mountpoint() {
    local mountpoint="$1"

    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi

    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

teardown_mountpoint() {
    local mountpoint
    mountpoint=$(realpath "$1")
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\\/'
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
}

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

chroot_dir=rootfs
overlay_dir=../overlay

rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
tar -xpJf "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir}

setup_mountpoint $chroot_dir

# 只更新索引，不升级，防止apt拉宿主/云内核
chroot $chroot_dir apt-get update
# chroot $chroot_dir apt-get -y upgrade  # 强烈建议注释掉，防止自动拉包

# board可选自定义hook
if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi

# 安装 uboot和build内核包
if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y install "u-boot-${BOARD}"
else
    cp "$uboot_package" "$linux_image_package" "$linux_headers_package" "$linux_modules_package" "$linux_buildinfo_package" "$linux_rockchip_headers_package" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{print \$2}')"
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/${linux_image_package} /tmp/${linux_headers_package} /tmp/${linux_modules_package} /tmp/${linux_buildinfo_package} /tmp/${linux_rockchip_headers_package}"
    # hold所有内核相关包，保证apt操作不会升级或拉包
    for pkg in "$linux_image_package" "$linux_headers_package" "$linux_modules_package" "$linux_buildinfo_package" "$linux_rockchip_headers_package"; do
        real_pkg_name=$(echo "$pkg" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')
        chroot "${chroot_dir}" apt-mark hold "$real_pkg_name"
    done
fi

# 更新initramfs
chroot ${chroot_dir} update-initramfs -u

# 清理
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean
chroot ${chroot_dir} apt-get -y autoremove
teardown_mountpoint $chroot_dir

cd ${chroot_dir} && tar -cpf "../ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
