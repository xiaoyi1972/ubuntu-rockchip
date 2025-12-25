# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
export COMPATIBLE_SUITES=("plucky")
export COMPATIBLE_FLAVORS=("server" "desktop")

# 通用的deb包构建函数
# 参数说明：
# $1: rootfs路径 (必填)
# $2: git仓库地址 (必填)
# $3: 工作目录（如tmp，会拼接成/${dir}/xxx） (必填)
# $4: 储存生成的deb包路径数组的变量
build_package_with() {
    local rootfs="$1"
    local repo="$2"
    local dir="$3"
    local result="$4"
    
    # 校验参数完整性
    if [[ -z "${rootfs}" || -z "${repo}" || -z "${dir}" ]]; then
        echo "Error: build_package_with 缺少必要参数" >&2
        exit 1
    fi

    # 提取仓库名称（去掉.git后缀）
    local repo_name=$(basename "${repo}" .git)
    local work_dir="/${dir}/${repo_name}"
    local build_log="/${dir}/build_${repo_name}.log"
    local deb_paths_collects=""
    # 1. 克隆/更新仓库
    echo "Cloning repo ${repo} to ${work_dir}..."
    chroot "${rootfs}" bash -c "rm -rf ${work_dir} && git clone --depth 1 ${repo} ${work_dir}" || {
        echo "Error: 克隆仓库 ${repo} 失败" >&2
        exit 1
    }

    # 2. 检查仓库文件并输出日志
    # echo "Checking repository files..."
    #.chroot "${rootfs}" bash -c "ls -lh ${work_dir}; cat ${work_dir}/debian/changelog || true"

    # 3. 构建deb包并保存日志
    echo "Building deb package, log saved to ${build_log}..."
    chroot "${rootfs}" bash -c "cd ${work_dir} && dpkg-buildpackage -us -uc -b -j$(nproc)" > "${rootfs}${build_log}" 2>&1 || {
        echo "Error: dpkg-buildpackage 失败，日志如下：" >&2
        cat "${rootfs}${build_log}" >&2
        exit 1
    }

    # 4. 从debian/control提取所有Package名称
    local packages
    packages=$(chroot "${rootfs}" bash -c "grep -E '^Package: ' ${work_dir}/debian/control | awk '{print \$2}'")
    if [[ -z "${packages}" ]]; then
        echo "Error: 未从 ${work_dir}/debian/control 中提取到Package名称" >&2
        exit 1
    fi

    # 5. 校验每个Package对应的deb包是否生成
    for pkg in ${packages}; do
        if ! chroot "${rootfs}" bash -c "ls /${dir}/${pkg}_*.deb >/dev/null 2>&1"; then
            echo "Error: /${dir}/${pkg}_*.deb 未生成" >&2
            exit 1
        fi
        echo "确认生成包: /${dir}/${pkg}_*.deb"
    done
    echo "所有Package对应的deb包已全部生成。"

    # 6. 收集所有生成的deb包路径并输出（作为函数返回值）
    # local deb_paths
    # deb_paths=$(chroot "${rootfs}" bash -c "for pkg in ${packages}; do ls /${dir}/\${pkg}_*.deb; done")
    # echo "${deb_paths}"

    # 6. 收集所有生成的deb包路径并输出（作为函数返回值）
    # chroot rootfs bash -c 'for pkg in bcmdhd-sdio-dkms bcmdhd-pcie-dkms bcmdhd-usb-dkms; do ls /tmp/${pkg}_*.deb 2>/dev/null; done'chroot rootfs bash -c 'for pkg in bcmdhd-sdio-dkms bcmdhd-pcie-dkms bcmdhd-usb-dkms; do ls /tmp/${pkg}_*.deb 2>/dev/null; done'local deb_paths=""
    for pkg in ${packages}; do
       # find更保险，如果没有文件不会报错
       found=$(chroot "${rootfs}" find "/${dir}" -maxdepth 1 -type f -name "${pkg}_*.deb" 2>/dev/null)
       if [[ -n "${found}" ]]; then
           deb_paths_collects="${deb_paths_collects} ${found}"
        fi
     done
     deb_paths_collects=$(echo "${deb_paths_collects}" | xargs)  # 去除多余空格
     # echo "${deb_paths}"
     # 最后赋值
     if [[ "$result" ]]; then
         # 注意：这里用间接变量展开（Bash）
         eval $result="'$deb_paths_collects'"
     fi
}

function config_image_hook__orangepi-5-max() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"
    local target_kernel_version="${TARGET_KERNEL_VERSION:-}"
    if [[ -n "${target_kernel_version}" ]]; then
        chroot "${rootfs}" bash -c "target_kernel_version='${target_kernel_version}'; for module_dir in /lib/modules/*; do if [ -d \"\$module_dir\" ]; then module_name=\$(basename \"\$module_dir\"); if [[ \"\$module_name\" =~ ^[0-9] && \"\$module_name\" != \"\$target_kernel_version\" ]]; then rm -rf \"\$module_dir\"; fi; fi; done"
        #chroot "${rootfs}" apt-get install -y libselinux-dev selinux-policy-dev || true
        if chroot "${rootfs}" test -d "/usr/src/linux-headers-${target_kernel_version}"; then
            chroot "${rootfs}" bash -c "apt -y install flex bison make"
            chroot "${rootfs}" bash -c "cd /usr/src/linux-headers-${target_kernel_version} && make -j$(nproc) CONFIG_SECURITY_SELINUX=n modules_prepare"
        fi
    fi
    local dkms_kernel_args=()
    if [[ -n "${target_kernel_version}" ]]; then
        dkms_kernel_args=(-k "${target_kernel_version}")
    fi
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
        # chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get install -y git dkms build-essential debhelper dh-dkms
        
        local deb_paths

        # build for mali-g610-firmware
        chroot "${rootfs}" apt-get -y install debhelper meson pkg-config libstdc++6 libgbm-dev libdrm-dev libx11-xcb1 libxcb-dri2-0 libxdamage1 libxext6 libwayland-client0 libwayland-dev libx11-dev cmake libdrm-dev libx11-xcb-dev
        build_package_with "${rootfs}" "https://github.com/tsukumijima/libmali-rockchip.git" "tmp" deb_paths
        for deb_path in ${deb_paths}; do
            if [[ "${deb_path}" == *"libmali-valhall-g610-g24p0-x11-wayland-gbm"* ]]; then
                if [[ -n "${deb_path}" ]]; then
                    chroot "${rootfs}" dpkg -i "${deb_path}" || chroot "${rootfs}" apt-get -y -f install 
                else
                    echo "Error: ${deb_path} 不存在"
                    exit 1
                fi
                break
            fi
        done


        # build for rockchip-firmware
        build_package_with "${rootfs}" "https://github.com/Joshua-Riek/firmware.git" "tmp" deb_paths
        for deb_path in ${deb_paths}; do
            if [[ -n "${deb_path}" ]]; then
                chroot "${rootfs}" dpkg -i "${deb_path}" || chroot "${rootfs}" apt-get -y -f install
                echo "${pkg_name} 安装完成"
            else
                echo "Error: ${deb_path} 不存在"
                #cat "${rootfs}/tmp/build_bcmdhd-dkms.log"
                exit 1
            fi
            break  
        done

        # build for bcmdhd-dkms
        build_package_with "${rootfs}" "https://github.com/Joshua-Riek/bcmdhd-dkms.git" "tmp" deb_paths

        # 遍历生成的deb包（这里示例只处理sdio版本，可根据实际需求调整）
        for deb_path in ${deb_paths}; do
            if [[ "${deb_path}" == *"bcmdhd-sdio-dkms_"* ]]; then
                # 只安装SDIO版本
                if [[ -n "${deb_path}" ]]; then
                    # sudo apt-get update (注：原代码此处sudo可能有问题，chroot内无需sudo)
                    # chroot "${rootfs}" dpkg -i "${deb_path}" || chroot "${rootfs}" apt-get -y -f install
                    chroot "${rootfs}" dpkg -i "${deb_path}" || chroot "${rootfs}" apt-get -y -f install || true
                    # 无论是否安装失败都尝试显示 make.log
                    log_path="${rootfs}/var/lib/dkms/bcmdhd-sdio/101.10.591.52.27-1/build/make.log"
                    if [[ -f "${log_path}" ]]; then
                       echo "======= 显示 make.log 日志 ======="
                       cat "${log_path}"
                       echo "======= 日志结束 ======="
                    else
                       echo "未找到 make.log: ${log_path}"
                    fi
                    # cat /var/lib/dkms/bcmdhd-sdio/101.10.591.52.27-1/build/make.log
                    # local bcmdhd_ver
                    # bcmdhd_ver=$(chroot "${rootfs}" bash -c "dpkg-deb -f \"${deb_path}\" Version")
                    # local pkg_name=$(basename "${deb_path}" | cut -d'_' -f1)
                    # chroot "${rootfs}" dkms add -m "${pkg_name}" -v "${bcmdhd_ver}"
                    # chroot "${rootfs}" dkms build -m "${pkg_name}" -v "${bcmdhd_ver}" "${dkms_kernel_args[@]}"
                    # chroot "${rootfs}" dkms install -m "${pkg_name}" -v "${bcmdhd_ver}" "${dkms_kernel_args[@]}"
                    # chroot "${rootfs}" dkms enable "${pkg_name}" || true
                    echo "${pkg_name} 安装完成"
                else
                    echo "Error: ${deb_path} 不存在"
                    cat "${rootfs}/tmp/build_bcmdhd-dkms.log"
                    exit 1
                fi
                break  # 找到sdio版本后退出循环
            fi
        done

        # Enable bluetooth
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${rootfs}/usr/bin/brcm_patchram_plus"
        cp "${overlay}/usr/lib/systemd/system/ap6611s-bluetooth.service" "${rootfs}/usr/lib/systemd/system/ap6611s-bluetooth.service"
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        # chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        # echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
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
