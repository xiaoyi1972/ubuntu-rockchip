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
            # Install the libmali blobs alongside panfork
            chroot "${rootfs}" apt-get -y install libmali-g610-x11
            # Install the rockchip camera engine
            chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588
        fi

        chroot "${rootfs}" apt-get update

        chroot "${rootfs}" apt-get install -y devscripts dh-exec lintian

        # 1. 进入chroot环境前，确保rootfs有网络访问权限
        cp /etc/resolv.conf "${rootfs}/etc/"
        # 2. chroot内安装构建依赖
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get -y install git dkms build-essential debhelper dh-dkms

        # 3. 克隆GitHub仓库到chroot环境
        chroot "${rootfs}" git clone https://github.com/Joshua-Riek/bcmdhd-dkms.git /tmp/bcmdhd-dkms

        # 4. 进入仓库目录，构建deb包
        chroot "${rootfs}" bash -c "cd /tmp/bcmdhd-dkms && dpkg-buildpackage -us -uc -b"

        # 5. 查找并安装生成的deb包，如果没有则立即中断
        bcmdhd_dkms_deb=$(chroot "${rootfs}" bash -c "find /tmp -maxdepth 1 -type f -name 'bcmdhd-dkms_*.deb' | head -n1")
        if [[ -n "$bcmdhd_dkms_deb" ]]; then
            chroot "${rootfs}" dpkg -i "$bcmdhd_dkms_deb" || chroot "${rootfs}" apt-get -y -f install
            chroot "${rootfs}" dkms add -m bcmdhd -v $(cat /tmp/bcmdhd-dkms/debian/changelog | head -n1 | grep -oP '\d+\.\d+\.\d+-\d+')
            chroot "${rootfs}" dkms build -m bcmdhd -v $(cat /tmp/bcmdhd-dkms/debian/changelog | head -n1 | grep -oP '\d+\.\d+\.\d+-\d+')
            chroot "${rootfs}" dkms install -m bcmdhd -v $(cat /tmp/bcmdhd-dkms/debian/changelog | head -n1 | grep -oP '\d+\.\d+\.\d+-\d+')
            chroot "${rootfs}" dkms enable bcmdhd
            echo "bcmdhd-dkms installed successfully via GitHub source"
        else
            echo "Error: bcmdhd-dkms deb 未生成, 中断构建流程"
            exit 1
        fi

        echo "install dkms"

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
        cp "${overlay}/usr/lib/systemd/
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
    fi

    return 0
}
