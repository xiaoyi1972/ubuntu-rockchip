# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
export COMPATIBLE_SUITES=("plucky")
export COMPATIBLE_FLAVORS=("server" "desktop")

function config_image_hook__orangepi-5-max() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"
    if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ] || [ "${suite}" == "oracular" ] || [ "${suite}" == "plucky" ]; then
        # Kernel modules to blacklist
        echo "blacklist bcmdhd" > "${rootfs}/etc/modprobe.d/bcmdhd.conf"
        echo "blacklist dhd_static_buf" >> "${rootfs}/etc/modprobe.d/bcmdhd.conf"

        if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ]; then
            # Install panfork
            chroot "${rootfs}" add-apt-repository -y ppa:jjriek/panfork-mesa
            chroot "${rootfs}" apt-get update
            chroot "${rootfs}" apt-get -y install mali-g610-firmware
            chroot "${rootfs}" apt-get -y dist-upgrade
            chroot "${rootfs}" apt-get -y install libmali-g610-x11
            chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588
        fi

        chroot "${rootfs}" apt-get update

        # 安装必要的打包依赖
        chroot "${rootfs}" apt-get install -y devscripts dh-exec lintian fakeroot dpkg-dev

        # 确保chroot环境有网络
        cp /etc/resolv.conf "${rootfs}/etc/"
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get install -y git dkms build-essential debhelper dh-dkms

        # 克隆 bcmdhd-dkms 仓库
        chroot "${rootfs}" bash -c "rm -rf /tmp/bcmdhd-dkms && git clone https://github.com/Joshua-Riek/bcmdhd-dkms.git /tmp/bcmdhd-dkms"

        # 检查仓库文件，增强日志
        chroot "${rootfs}" bash -c "ls -lh /tmp/bcmdhd-dkms; cat /tmp/bcmdhd-dkms/debian/changelog || true"

        # 构建deb包并保存日志
        chroot "${rootfs}" bash -c 'cd /tmp/bcmdhd-dkms && dpkg-buildpackage -us -uc -b' > "${rootfs}/tmp/build_bcmdhd.log" 2>&1 || {
            echo "Error: dpkg-buildpackage 失败，日志如下："
            cat "${rootfs}/tmp/build_bcmdhd.log"
            exit 1
        }

        # 校验三个子包都存在
        chroot "${rootfs}" bash -c '
            for t in pcie sdio usb; do
                if ! ls /tmp/bcmdhd-${t}-dkms_*.deb >/dev/null 2>&1; then
                    echo "Error: /tmp/bcmdhd-${t}-dkms deb 未生成"
                    exit 1
                fi
            done
        '
        echo "bcmdhd pcie/sdio/usb dkms deb 已全部生成。"

        # 只安装SDIO版本
        bcmdhd_sdio_deb=$(chroot "${rootfs}" bash -c "ls /tmp/bcmdhd-sdio-dkms_*.deb | head -n1")
        if [[ -n "$bcmdhd_sdio_deb" ]]; then
            chroot "${rootfs}" dpkg -i "$bcmdhd_sdio_deb" || chroot "${rootfs}" apt-get -y -f install
            bcmdhd_ver=$(chroot "${rootfs}" bash -c "dpkg-deb -f \"$bcmdhd_sdio_deb\" Version")
            chroot "${rootfs}" dkms add -m bcmdhd-sdio -v "$bcmdhd_ver"
            chroot "${rootfs}" dkms build -m bcmdhd-sdio -v "$bcmdhd_ver"
            chroot "${rootfs}" dkms install -m bcmdhd-sdio -v "$bcmdhd_ver"
            chroot "${rootfs}" dkms enable bcmdhd-sdio || true
            echo "bcmdhd-sdio-dkms 安装完成"
        else
            echo "Error: bcmdhd-sdio-dkms deb 未生成"
            cat "${rootfs}/tmp/build_bcmdhd.log"
            exit 1
        fi

        # Enable bluetooth
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${rootfs}/usr/bin/brcm_patchram_plus"
        cp "${overlay}/usr/lib/systemd/system/ap6611s-bluetooth.service" "${rootfs}/usr/lib/systemd/system/ap6611s-bluetooth.service"
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
    fi
    return 0
}

function old_config_image_hook__orangepi-5-max_other() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"

    if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ] || [ "${suite}" == "oracular" ] || [ "${suite}" == "plucky" ]; then
        # Kernel modules to blacklist
        echo "blacklist bcmdhd" > "${rootfs}/etc/modprobe.d/bcmdhd.conf"
        echo "blacklist dhd_static_buf" >> "${rootfs}/etc/modprobe.d/bcmdhd.conf"

        if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ]; then
            # Install panfork
            chroot "${rootfs}" add-apt-repository -y ppa:jjriek/panfork-mesa
            chroot "${rootfs}" apt-get update
            chroot "${rootfs}" apt-get -y install mali-g610-firmware
            chroot "${rootfs}" apt-get -y dist-upgrade

            # Install libmali blobs alongside panfork
            chroot "${rootfs}" apt-get -y install libmali-g610-x11

            # Install the rockchip camera engine
            chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588
        fi

        # Add old package for test
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/rockchip
        chroot "${rootfs}" apt-get update

        # Install BCMDHD SDIO WiFi and Bluetooth DKMS
        chroot "${rootfs}" apt-get -y install dkms bcmdhd-sdio-dkms

        # Enable bluetooth
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${rootfs}/usr/bin/brcm_patchram_plus"
        cp "${overlay}/usr/lib/systemd/system/ap6611s-bluetooth.service" "${rootfs}/usr/lib/systemd/system/ap6611s-bluetooth.service"
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
    fi

    return 0
}
