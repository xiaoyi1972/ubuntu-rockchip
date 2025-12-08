# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
#export COMPATIBLE_SUITES=("jammy" "noble" "oracular" "plucky")
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

            # Install libmali blobs alongside panfork
            chroot "${rootfs}" apt-get -y install libmali-g610-x11
            
            # Install the rockchip camera engine
            chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588
        fi
        
        if [ "${suite}" == "plucky" ]; then
            # ===================== 替换后的BCMDHD DKMS安装逻辑 =====================
            # Install BCMDHD PCIe/SDIO/USB DKMS packages (替换原单行安装)
            # 定义deb包URL列表
            local -a BCMDHD_DEB_URLS=(
                "https://github.com/armbian/bcmdhd-dkms/releases/download/101.10.591.52.27-5/bcmdhd-pcie-dkms_101.10.591.52.27-5_all.deb"
                "https://github.com/armbian/bcmdhd-dkms/releases/download/101.10.591.52.27-5/bcmdhd-sdio-dkms_101.10.591.52.27-5_all.deb"
                "https://github.com/armbian/bcmdhd-dkms/releases/download/101.10.591.52.27-5/bcmdhd-usb-dkms_101.10.591.52.27-5_all.deb"
            )
        
            # 创建临时目录（主机端和rootfs内）
            local HOST_TMP_DIR="/tmp/bcmdhd-dkms-$(date +%Y%m%d%H%M%S)"
            local ROOTFS_TMP_DIR="/tmp/bcmdhd-dkms"
            mkdir -p "${HOST_TMP_DIR}" || {
                echo "Error: 无法创建主机临时目录 ${HOST_TMP_DIR}" >&2
                return 1
            }
            mkdir -p "${rootfs}${ROOTFS_TMP_DIR}" || {
                echo "Error: 无法创建rootfs临时目录 ${rootfs}${ROOTFS_TMP_DIR}" >&2
                rm -rf "${HOST_TMP_DIR}"
                return 1
            }
        
            # 检测主机端下载工具（curl/wget）
            local DOWNLOAD_CMD
            if command -v curl &> /dev/null; then
                DOWNLOAD_CMD="curl -fsSL -o"  # 静默下载，跟随重定向
            elif command -v wget &> /dev/null; then
                DOWNLOAD_CMD="wget -qO"      # 静默下载
            else
                echo "Error: 主机未安装curl/wget，无法下载deb包！" >&2
                rm -rf "${HOST_TMP_DIR}" "${rootfs}${ROOTFS_TMP_DIR}"
                return 1
            fi
        
            # 下载deb包到主机临时目录
            echo "Downloading BCMDHD DKMS packages..."
            for deb_url in "${BCMDHD_DEB_URLS[@]}"; do
                local deb_filename=$(basename "${deb_url}")
                local deb_host_path="${HOST_TMP_DIR}/${deb_filename}"
            
                # 执行下载
                ${DOWNLOAD_CMD} "${deb_host_path}" "${deb_url}" || {
                    echo "Error: 下载失败 - ${deb_url}" >&2
                    rm -rf "${HOST_TMP_DIR}" "${rootfs}${ROOTFS_TMP_DIR}"
                    return 1
                }
            
                # 验证下载文件有效性
                if [ ! -s "${deb_host_path}" ]; then
                    echo "Error: 下载的文件为空 - ${deb_host_path}" >&2
                    rm -rf "${HOST_TMP_DIR}" "${rootfs}${ROOTFS_TMP_DIR}"
                    return 1
                fi
            done
        
            # 复制deb包到rootfs临时目录
            cp "${HOST_TMP_DIR}"/*.deb "${rootfs}${ROOTFS_TMP_DIR}/" || {
                echo "Error: 无法复制deb包到rootfs" >&2
                rm -rf "${HOST_TMP_DIR}" "${rootfs}${ROOTFS_TMP_DIR}"
                return 1
            }
        
            # 在chroot环境内安装DKMS依赖和deb包
            echo "Installing BCMDHD DKMS packages in rootfs..."
            chroot "${rootfs}" apt-get update -q || echo "Warning: apt update 警告（不影响安装）"
            chroot "${rootfs}" apt-get install -y dkms "${ROOTFS_TMP_DIR}"/*.deb || {
                echo "Error: BCMDHD DKMS包安装失败" >&2
                rm -rf "${HOST_TMP_DIR}" "${rootfs}${ROOTFS_TMP_DIR}"
                return 1
            }
        
            # 清理临时文件
            rm -rf "${HOST_TMP_DIR}"
            chroot "${rootfs}" rm -rf "${ROOTFS_TMP_DIR}"
            echo "BCMDHD DKMS packages installed successfully!"
            
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
