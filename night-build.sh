#!/bin/bash
set -euo pipefail  # 严格模式：出错立即退出、未定义变量报错、管道失败触发退出

# ===================== 核心配置项（可根据实际环境调整）=====================
# 仓库根目录（脚本需放在仓库根目录运行，或手动指定绝对路径）
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# 产物保存目录（替代 GitHub Action 的 Artifact）
ARTIFACT_DIR="${REPO_ROOT}/artifacts"
# 构建临时目录
BUILD_DIR="${REPO_ROOT}/build"
IMAGE_DIR="${REPO_ROOT}/images"
# Ubuntu 源镜像（国内用户建议改为阿里云/清华源）
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu/"
# UBUNTU_MIRROR="https://mirrors.aliyun.com/ubuntu/"  # 国内镜像（可选）

# ===================== 工具函数 =====================
# 带时间戳的日志打印
log() {
    echo -e "\033[32m[$(date +%Y-%m-%d\ %H:%M:%S)] $1\033[0m"
}

# 错误打印并退出
error() {
    echo -e "\033[31m[$(date +%Y-%m-%d\ %H:%M:%S)] $1\033[0m"
    exit 1
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "核心命令 '$1' 未找到，请先安装"
    fi
}

# ===================== 步骤1：前置检查 =====================
log "===== 【步骤1/10】前置环境检查 ====="
# 检查脚本运行目录（必须存在 build.sh）
if [ ! -f "${REPO_ROOT}/build.sh" ]; then
    error "未找到核心构建脚本 build.sh，请确保脚本在仓库根目录运行"
fi

# 检查核心依赖命令
check_command "sudo"
check_command "apt-get"
check_command "bash"
check_command "wget"
check_command "sed"

# 创建必要目录
mkdir -p "${ARTIFACT_DIR}" "${BUILD_DIR}" "${IMAGE_DIR}"
log "已创建工作目录：ARTIFACT_DIR=${ARTIFACT_DIR}, BUILD_DIR=${BUILD_DIR}"

# ===================== 步骤2：清理磁盘空间（WSL2 适配）=====================
log "===== 【步骤2/10】清理磁盘空间 ====="
# 清理系统冗余包和缓存
sudo apt-get autoremove -y --purge
sudo apt-get clean -y
sudo rm -rf /var/cache/apt/* /var/lib/apt/lists/*
# 清理 swap（可选，释放磁盘）
sudo swapoff -a || log "swap 清理失败，忽略"
sudo rm -rf /swapfile || log "swap 文件不存在，忽略"
log "磁盘空间清理完成"

# ===================== 步骤3：生成构建矩阵（替代 GitHub Action 的 config Job）=====================
log "===== 【步骤3/10】生成构建矩阵 ====="
# 矩阵文件路径
BUILD_MATRIX_FILE="${ARTIFACT_DIR}/build_matrix.txt"
ROOTFS_MATRIX_FILE="${ARTIFACT_DIR}/rootfs_matrix.txt"
# 清空旧矩阵文件
> "${BUILD_MATRIX_FILE}"
> "${ROOTFS_MATRIX_FILE}"

# 生成 rootfs 矩阵（suite + flavor）
log "生成 rootfs 矩阵（suite × flavor）"
for suite_sh in "${REPO_ROOT}/config/suites/"*.sh; do
    [ -f "${suite_sh}" ] || continue  # 跳过空目录/非文件
    suite=$(basename "${suite_sh%.sh}")
    for flavor_sh in "${REPO_ROOT}/config/flavors/"*.sh; do
        [ -f "${flavor_sh}" ] || continue
        flavor=$(basename "${flavor_sh%.sh}")
        echo "${suite}|${flavor}" >> "${ROOTFS_MATRIX_FILE}"
    done
done

# 生成 build 矩阵（board + suite + flavor）
log "生成 build 矩阵（board × suite × flavor）"
for board_sh in "${REPO_ROOT}/config/boards/"*.sh; do
    [ -f "${board_sh}" ] || continue
    board=$(basename "${board_sh%.sh}")
    # 加载板卡配置的兼容套件/风味
    COMPATIBLE_SUITES=()
    COMPATIBLE_FLAVORS=()
    # shellcheck disable=SC1090
    source "${board_sh}" || error "加载板卡配置 ${board_sh} 失败"
    # 拼接矩阵
    for suite in "${COMPATIBLE_SUITES[@]}"; do
        for flavor in "${COMPATIBLE_FLAVORS[@]}"; do
            echo "${board}|${suite}|${flavor}" >> "${BUILD_MATRIX_FILE}"
        done
    done
done

# 检查矩阵非空
if [ ! -s "${ROOTFS_MATRIX_FILE}" ]; then
    error "rootfs 矩阵为空！请检查 config/suites 或 config/flavors 目录"
fi
if [ ! -s "${BUILD_MATRIX_FILE}" ]; then
    error "build 矩阵为空！请检查 config/boards 目录"
fi
log "矩阵生成完成：rootfs 组合数=$(wc -l < "${ROOTFS_MATRIX_FILE}"), build 组合数=$(wc -l < "${BUILD_MATRIX_FILE}")"

# ===================== 步骤4：安装构建依赖（Ubuntu 24.04 适配）=====================
log "===== 【步骤4/10】安装构建依赖 ====="
# 启用 universe 仓库（必要依赖所在）
sudo add-apt-repository -y universe
# 替换 apt 源（可选，国内用户启用）
if [ "${UBUNTU_MIRROR}" != "http://archive.ubuntu.com/ubuntu/" ]; then
    sudo sed -i "s|http://archive.ubuntu.com/ubuntu/|${UBUNTU_MIRROR}|g" /etc/apt/sources.list
    log "已替换 apt 镜像源为：${UBUNTU_MIRROR}"
fi
sudo apt-get update -y

# 安装核心依赖（适配 24.04，替换废弃包名）
sudo apt-get install -y \
    build-essential gcc-aarch64-linux-gnu bison \
    qemu-user-static qemu-system-arm qemu-efi-arm u-boot-tools binfmt-support \
    debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
    udev dosfstools uuid-runtime git-lfs device-tree-compiler python3 \
    python-is-python3 fdisk bc debhelper python3-pyelftools python3-setuptools \
    python3-pkg-resources swig libfdt-dev libpython3-dev dctrl-tools wget live-build

# 解决 python3-distutils 依赖（24.04 替代方案）
if ! python3 -c "import distutils" &> /dev/null; then
    log "补充安装 distutils 兼容层"
    sudo pip3 install setuptools==65.5.0
    sudo ln -s /usr/lib/python3/dist-packages/pkg_resources /usr/lib/python3/dist-packages/distutils || true
fi
log "依赖安装完成"

# ===================== 步骤5：预处理修复（解决 Seeds URL/缺失文件问题）=====================
log "===== 【步骤5/10】预处理修复（适配 Ubuntu 源变更）====="
# 1. 补充缺失的 extra-ppas.pref.chroot 文件
mkdir -p "${REPO_ROOT}/config/archives"
touch "${REPO_ROOT}/config/archives/extra-ppas.pref.chroot"
# 添加默认 PPA 优先级配置（避免警告）
cat > "${REPO_ROOT}/config/archives/extra-ppas.pref.chroot" << EOF
Package: *
Pin: release o=LP-PPA-*
Pin-Priority: 500
EOF
log "已创建缺失文件：config/archives/extra-ppas.pref.chroot"

# 2. 替换 build-rootfs.sh 中的失效 Seeds URL
BUILD_ROOTFS_SH="${REPO_ROOT}/scripts/build-rootfs.sh"
if [ -f "${BUILD_ROOTFS_SH}" ]; then
    # 替换旧 URL 为 Launchpad 镜像
    sed -i 's|https://ubuntu-archive-team.ubuntu.com/seeds/|https://git.launchpad.net/ubuntu-seeds/plain/|g' "${BUILD_ROOTFS_SH}"
    # 补充 git 分支参数（适配 Launchpad 路径）
    sed -i 's|/boot|/boot?h=ubuntu/\${SUITE}|g' "${BUILD_ROOTFS_SH}"
    log "已修复 build-rootfs.sh 中的 Seeds URL"
else
    log "警告：未找到 build-rootfs.sh，跳过 URL 替换"
fi

# ===================== 步骤6：安装 Python2.7（Ubuntu 24.04 源码编译）=====================
log "===== 【步骤6/10】安装 Python2.7（适配 24.04）====="
if command -v python2 &> /dev/null; then
    # 已安装 Python2，跳过编译
    PY2_VERSION=$(python2 --version 2>&1 | awk '{print $2}')
    if [[ "${PY2_VERSION}" == 2.7.* ]]; then
        log "系统已安装 Python2.7（版本：${PY2_VERSION}），跳过编译"
    else
        error "Python2 版本错误（要求 2.7.x），当前：${PY2_VERSION}"
    fi
else
    # 源码编译安装 Python2.7.18
    log "开始编译安装 Python2.7.18（Ubuntu 24.04 无官方包）"
    # 安装编译依赖
    sudo apt-get install -y build-essential libssl-dev libffi-dev zlib1g-dev \
        libncurses5-dev libreadline6-dev libsqlite3-dev libbz2-dev

    # 下载源码
    PY2_VERSION="2.7.18"
    PY2_TAR="Python-${PY2_VERSION}.tgz"
    PY2_URL="https://www.python.org/ftp/python/${PY2_VERSION}/${PY2_TAR}"
    wget -q "${PY2_URL}" -O "/tmp/${PY2_TAR}" || error "下载 Python2 源码失败"

    # 编译安装
    mkdir -p /tmp/python2-build
    tar xf "/tmp/${PY2_TAR}" -C /tmp/python2-build --strip-components=1
    cd /tmp/python2-build
    ./configure --prefix=/usr/local/python2 --enable-unicode=ucs4 --enable-shared
    make -j"$(nproc)"  # 多核编译加速
    sudo make install

    # 创建软链接
    sudo ln -s /usr/local/python2/bin/python2.7 /usr/bin/python2
    sudo ln -s /usr/local/python2/bin/pip2.7 /usr/bin/pip2

    # 配置动态库
    echo "/usr/local/python2/lib" | sudo tee /etc/ld.so.conf.d/python2.conf
    sudo ldconfig

    # 清理临时文件
    cd -
    sudo rm -rf /tmp/python2-build /tmp/${PY2_TAR}

    # 验证安装
    if ! command -v python2 &> /dev/null; then
        error "Python2.7 编译安装失败"
    fi
    log "Python2.7 安装成功：$(python2 --version)"
fi

# ===================== 步骤7：构建根文件系统（替代 GitHub Action 的 rootfs Job）=====================
log "===== 【步骤7/10】构建根文件系统（RootFS）====="
while IFS="|" read -r suite flavor; do
    [ -z "${suite}" ] || [ -z "${flavor}" ] && continue  # 跳过空行
    log "开始构建 RootFS：suite=${suite}, flavor=${flavor}"

    # 加载套件版本号
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/config/suites/${suite}.sh" || error "加载套件配置 ${suite}.sh 失败"
    suite_version="${RELEASE_VERSION:-unknown}"
    log "套件 ${suite} 版本：${suite_version}"

    # 执行根文件系统构建
    sudo "${REPO_ROOT}/build.sh" \
        --suite="${suite}" \
        --flavor="${flavor}" \
        --rootfs-only \
        --launchpad || error "RootFS 构建失败：${suite}-${flavor}"

    # 保存产物到 Artifact 目录
    rootfs_file="${BUILD_DIR}/ubuntu-${suite_version}-preinstalled-${flavor}-arm64.rootfs.tar.xz"
    if [ ! -f "${rootfs_file}" ]; then
        error "RootFS 产物缺失：${rootfs_file}"
    fi
    cp -f "${rootfs_file}" "${ARTIFACT_DIR}/"
    log "RootFS 产物已保存：${ARTIFACT_DIR}/$(basename "${rootfs_file}")"
done < "${ROOTFS_MATRIX_FILE}"
log "所有 RootFS 构建完成"

# ===================== 步骤8：构建板卡镜像（替代 GitHub Action 的 build Job）=====================
log "===== 【步骤8/10】构建板卡专属镜像 ====="
while IFS="|" read -r board suite flavor; do
    [ -z "${board}" ] || [ -z "${suite}" ] || [ -z "${flavor}" ] && continue
    log "开始构建镜像：board=${board}, suite=${suite}, flavor=${flavor}"

    # 加载套件版本号
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/config/suites/${suite}.sh" || error "加载套件配置 ${suite}.sh 失败"
    suite_version="${RELEASE_VERSION:-unknown}"

    # 复制 RootFS 产物到构建目录
    rootfs_artifact="${ARTIFACT_DIR}/ubuntu-${suite_version}-preinstalled-${flavor}-arm64.rootfs.tar.xz"
    if [ ! -f "${rootfs_artifact}" ]; then
        error "RootFS 产物缺失：${rootfs_artifact}"
    fi
    cp -f "${rootfs_artifact}" "${BUILD_DIR}/"

    # 执行镜像构建
    sudo "${REPO_ROOT}/build.sh" \
        --board="${board}" \
        --suite="${suite}" \
        --flavor="${flavor}" \
        --launchpad || error "镜像构建失败：${board}-${suite}-${flavor}"

    # 保存镜像产物
    image_pattern="${IMAGE_DIR}/ubuntu-*-preinstalled-${flavor}-arm64-${board}.*"
    if ! ls ${image_pattern} &> /dev/null; then
        error "镜像产物缺失：${image_pattern}"
    fi
    cp -f ${image_pattern} "${ARTIFACT_DIR}/"
    log "镜像产物已保存：${ARTIFACT_DIR}/$(basename ${image_pattern})"

    # 清理当前板卡临时文件
    sudo rm -rf "${BUILD_DIR}/"* "${IMAGE_DIR}/"*
    sync
done < "${BUILD_MATRIX_FILE}"
log "所有板卡镜像构建完成"

# ===================== 步骤9：最终清理 =====================
log "===== 【步骤9/10】最终清理 ====="
sudo rm -rf "${BUILD_DIR}" "${IMAGE_DIR}"
sudo apt-get autoremove -y
sudo apt-get clean -y
log "临时文件清理完成"

# ===================== 步骤10：构建完成 =====================
log "===== 【步骤10/10】构建全部完成 ====="
log "所有产物已保存到：${ARTIFACT_DIR}"
ls -lh "${ARTIFACT_DIR}"
log "脚本执行完毕，无异常"