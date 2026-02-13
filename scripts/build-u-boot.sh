#!/bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# ===================== 第一步：Docker 环境初始化 + 路径解析 =====================
# 复用内核构建的 Docker 镜像（保证编译环境一致性）
DOCKER_IMAGE="ubuntu-kernel-u-boot-build:dynamic"

# 稳定的路径解析（兼容 WSL/原生 Linux，添加调试输出）
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
HOST_UBOOT_ROOT=$(realpath "${SCRIPT_DIR}/.." 2>/dev/null)

# 调试：输出路径信息（便于移植时排查）
echo "===== U-Boot 构建路径调试信息 ====="
echo "脚本绝对路径: ${SCRIPT_PATH}"
echo "脚本所在目录: ${SCRIPT_DIR}"
echo "U-Boot 构建根目录: ${HOST_UBOOT_ROOT}"

# 国内 Ubuntu 镜像仓库（与内核构建保持一致）
UBUNTU_MIRROR="hub-mirror.c.163.com/library/ubuntu"

# ===================== 第二步：环境变量检查 =====================
# 检查 SUITE 是否设置（加载对应版本配置）
if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set (e.g. export SUITE=plucky)"
    exit 1
fi

# 检查 UBOOT_PACKAGE 是否设置（U-Boot 核心变量）
if [[ -z ${UBOOT_PACKAGE} ]]; then
    echo "Error: UBOOT_PACKAGE is not set (e.g. export UBOOT_PACKAGE=u-boot-rockchip)"
    exit 1
fi

# 加载 Suite 配置文件（如 plucky.sh）
SUITE_CONFIG_FILE="${HOST_UBOOT_ROOT}/config/suites/${SUITE}.sh"
if [ ! -f "${SUITE_CONFIG_FILE}" ]; then
    echo "Error: Suite 配置文件不存在 → ${SUITE_CONFIG_FILE}"
    exit 1
fi
# shellcheck source=/dev/null
source "${SUITE_CONFIG_FILE}"

# 提取 Ubuntu 版本（从 plucky.sh 的 RELEASE_VERSION）
UBUNTU_VERSION="${RELEASE_VERSION}"
# 校验 UBUNTU_VERSION 非空
if [ -z "${UBUNTU_VERSION}" ]; then
    echo "Error: RELEASE_VERSION 未在 ${SUITE_CONFIG_FILE} 中定义"
    echo "请检查 ${SUITE_CONFIG_FILE} 中是否有：RELEASE_VERSION=\"25.04\""
    exit 1
fi

# 调试输出核心变量
echo "===== U-Boot 核心变量校验 ====="
echo "SUITE: ${SUITE}"
echo "UBUNTU_VERSION: ${UBUNTU_VERSION}"
echo "UBOOT_PACKAGE: ${UBOOT_PACKAGE}"
echo "UBOOT_RULES_TARGET: ${UBOOT_RULES_TARGET:-未设置}"
echo "UBOOT_RULES_TARGET_EXTRA: ${UBOOT_RULES_TARGET_EXTRA:-未设置}"

# ===================== 第三步：Docker 权限修复（复用内核构建逻辑） =====================
fix_docker_permission() {
    echo "===== 检查 Docker 权限 ====="
    # 兼容无 systemctl 的环境（如 WSL/Docker Desktop）
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active --quiet docker; then
            echo "启动 Docker 服务..."
            systemctl start docker || echo "警告：Docker 服务启动失败（可能是 Docker Desktop 环境）"
            systemctl enable docker || true
        fi
    fi

    # 修复 Docker 套接字权限
    DOCKER_SOCK="/var/run/docker.sock"
    if [ -S "${DOCKER_SOCK}" ] && [ ! -w "${DOCKER_SOCK}" ]; then
        echo "修复 Docker 套接字权限..."   
        chmod 666 "${DOCKER_SOCK}" || echo "警告：无法修改 ${DOCKER_SOCK} 权限"
        if [ -n "${SUDO_USER}" ]; then
            usermod -aG docker "${SUDO_USER}" || true
            newgrp docker &> /dev/null
        fi
    fi

    # 验证 Docker 可用性
    if ! docker info &> /dev/null; then
        echo "Error: Docker 权限修复失败/未安装，请检查 Docker 环境"
        exit 1
    fi
    echo "Docker 权限检查通过"
}

# ===================== 第四步：基础环境检查（Docker 安装） =====================
# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "===== 安装 Docker 环境 ====="
    apt-get update && apt-get install -y --no-install-recommends docker.io
    if [ -n "${SUDO_USER}" ]; then
        usermod -aG docker "${SUDO_USER}" || true
        newgrp docker &> /dev/null
    fi
fi

# 修复 Docker 权限
fix_docker_permission() {
    echo "===== 检查 Docker 权限 ====="
    # 兼容无 systemctl 的环境（如 WSL/Docker Desktop）
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active --quiet docker; then
            echo "启动 Docker 服务..."
            systemctl start docker || echo "警告：Docker 服务启动失败（可能是 Docker Desktop 环境）"
            systemctl enable docker || true
        fi
    fi

    # 修复 Docker 套接字权限
    DOCKER_SOCK="/var/run/docker.sock"
    if [ -S "${DOCKER_SOCK}" ] && [ ! -w "${DOCKER_SOCK}" ]; then
        echo "修复 Docker 套接字权限..."   
        chmod 666 "${DOCKER_SOCK}" || echo "警告：无法修改 ${DOCKER_SOCK} 权限"
        if [ -n "${SUDO_USER}" ]; then
            usermod -aG docker "${SUDO_USER}" || true
            newgrp docker &> /dev/null
        fi
    fi

    # 验证 Docker 可用性
    if ! docker info &> /dev/null; then
        echo "Error: Docker 权限修复失败/未安装，请检查 Docker 环境"
        exit 1
    fi
    echo "Docker 权限检查通过"
}

# ===================== 第五步：构建 Docker 镜像（包含 U-Boot 编译依赖） =====================
if ! docker images | grep -q "${DOCKER_IMAGE}"; then
    echo "===== 构建 U-Boot 编译 Docker 镜像 ====="
    # 验证构建上下文路径存在
    if [ ! -d "${HOST_UBOOT_ROOT}" ]; then
        echo "Error: 构建上下文路径不存在 → ${HOST_UBOOT_ROOT}"
        exit 1
    fi

    # 生成临时 Dockerfile
    TEMP_DOCKERFILE=$(mktemp)
    echo "调试：临时 Dockerfile 路径 = ${TEMP_DOCKERFILE}"
    cat > "${TEMP_DOCKERFILE}" << EOF
# 定义 ARG（必须在 FROM 前）
ARG UBUNTU_VERSION=25.04
# 基础镜像
# FROM ubuntu:\${UBUNTU_VERSION}
FROM ghcr.io/sfqr0414/ubuntu:${UBUNTU_VERSION}

# 定义容器内需要的 ARG
ARG UBUNTU_VERSION

# 【关键修复】将 ARG 转为 ENV，确保 RUN 阶段能读取到
ENV UBUNTU_VERSION=\${UBUNTU_VERSION}

# 全局环境变量（消除交互警告）
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
ENV LANG=C.UTF-8
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 安装 U-Boot 编译依赖（包含 cpio 解决 command not found 问题）
RUN <<SCRIPT
#!/bin/bash
set -eE
trap 'echo "环境构建错误: 行号 \$LINENO"; exit 1' ERR

# 升级系统并安装依赖
apt-get update && \
apt-get upgrade -y || true && \
apt-get install -y --no-install-recommends \
lsb-release u-boot-tools device-tree-compiler libfdt-dev parted \
debhelper fakeroot build-essential dpkg-dev devscripts \
gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
git wget cpio bc bison flex libssl-dev libncurses-dev \
libelf-dev dwarves libterm-readline-gnu-perl && \
apt-get clean && rm -rf /var/lib/apt/lists/*

# 校验关键依赖
echo "===== 校验 U-Boot 编译依赖 ====="
# 校验 cpio（解决核心报错）
if ! command -v cpio; then
    echo "Error: cpio 安装失败"
    exit 1
fi
echo "cpio 版本: \$(cpio --version | head -1)"

# 校验交叉编译工具链
if ! command -v aarch64-linux-gnu-gcc; then
    echo "Error: aarch64-linux-gnu-gcc 安装失败"
    exit 1
fi
echo "aarch64-linux-gnu-gcc 版本: \$(aarch64-linux-gnu-gcc --version | head -1)"

# 校验 Ubuntu 版本
ACTUAL_UBUNTU_VERSION=\$(lsb_release -rs)
echo "容器内 Ubuntu 版本: \$ACTUAL_UBUNTU_VERSION"
if [ "\$ACTUAL_UBUNTU_VERSION" != "\${UBUNTU_VERSION}" ]; then
    echo "版本不匹配：预期 \${UBUNTU_VERSION}，实际 \$ACTUAL_UBUNTU_VERSION"
    exit 1
fi
SCRIPT

# 设置工作目录
WORKDIR /u-boot-build
EOF

    # 执行 Docker 构建
    echo "===== 执行 Docker Build ====="
    docker build \
        --no-cache \
        --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
        -t "${DOCKER_IMAGE}" \
        -f "${TEMP_DOCKERFILE}" \
        "${HOST_UBOOT_ROOT}"

    # 清理临时 Dockerfile
    rm -f "${TEMP_DOCKERFILE}"
else
    echo "Docker 镜像已存在，跳过构建步骤"
fi

# ===================== 第六步：容器内执行 U-Boot 编译逻辑 =====================
echo "===== 启动容器构建 U-Boot ====="

# 生成容器内执行脚本
CONTAINER_SCRIPT=$(mktemp)
cat > "${CONTAINER_SCRIPT}" << 'EOF'
#!/bin/bash
set -eE
trap 'echo "容器内 U-Boot 编译错误: 行号 $LINENO"; exit 1' ERR

# 容器内调试信息
echo "===== 容器内 U-Boot 编译环境 ====="
echo "当前工作目录: $(pwd)"
echo "容器内 U-Boot 根目录: /u-boot-build"
echo "UBOOT_PACKAGE: ${UBOOT_PACKAGE}"

# 校验关键依赖（容器内二次确认）
echo "===== 容器内依赖最终校验 ====="
command -v cpio || { echo "Error: cpio 未安装"; exit 1; }
command -v dpkg-buildpackage || { echo "Error: dpkg-buildpackage 未安装"; exit 1; }
command -v aarch64-linux-gnu-gcc || { echo "Error: aarch64-linux-gnu-gcc 未安装"; exit 1; }

# 校验 dtc (device-tree-compiler)
if ! command -v dtc; then
    echo "Error: dtc (device-tree-compiler) 安装失败"
    exit 1
fi
echo "dtc 版本: \$(dtc --version | head -1)"
echo "dtc 路径: \$(which dtc)"

# 创建 build 目录并切换
mkdir -p build && cd build || { echo "创建/进入 build 目录失败"; exit 1; }

# 克隆 U-Boot 源码（如果不存在）
if [ ! -d "${UBOOT_PACKAGE}" ]; then
    echo "===== 克隆 U-Boot 源码 ====="
    # 加载 upstream 配置（包含 GIT/BRANCH/COMMIT）
    source ../packages/"${UBOOT_PACKAGE}"/debian/upstream || {
        echo "Error: 加载 upstream 配置失败 → ../packages/${UBOOT_PACKAGE}/debian/upstream"
        exit 1
    }
    echo "克隆仓库: ${GIT} 分支: ${BRANCH} 提交: ${COMMIT}"
    git clone --single-branch --progress -b "${BRANCH}" "${GIT}" "${UBOOT_PACKAGE}" || {
        echo "Error: Git 克隆失败"; exit 1;
    }
    git -C "${UBOOT_PACKAGE}" checkout "${COMMIT}" || {
        echo "Error: 切换到指定提交失败"; exit 1;
    }
    # 复制 debian 目录
    cp -r ../packages/"${UBOOT_PACKAGE}"/debian "${UBOOT_PACKAGE}" || {
        echo "Error: 复制 debian 目录失败"; exit 1;
    }
else
    echo "===== U-Boot 源码已存在，跳过克隆 ====="
fi

# 进入 U-Boot 源码目录
cd "${UBOOT_PACKAGE}" || { echo "进入 ${UBOOT_PACKAGE} 目录失败"; exit 1; }

# 构建 rules 目标（兼容额外目标）
echo "===== 构建 U-Boot 编译规则 ====="
rules=${UBOOT_RULES_TARGET},package-${UBOOT_RULES_TARGET}
if [[ -n ${UBOOT_RULES_TARGET_EXTRA} ]]; then
    rules=${UBOOT_RULES_TARGET_EXTRA},${rules}
fi
echo "编译规则目标: ${rules}"

# 编译 U-Boot 为 deb 包
echo "===== 开始编译 U-Boot ====="
dpkg-source --before-build . || { echo "dpkg-source --before-build 失败"; exit 1; }
dpkg-buildpackage -a "$(cat debian/arch)" -d -b -nc -uc --rules-target="${rules}" || {
    echo "Error: dpkg-buildpackage 编译失败"; exit 1;
}
dpkg-source --after-build . || { echo "dpkg-source --after-build 失败"; exit 1; }

# 清理无用文件
rm -f ../*.buildinfo ../*.changes || { echo "警告：清理 buildinfo/changes 文件失败"; }

# 输出编译结果
echo "===== U-Boot 编译完成 ====="
ls -lh ../*.deb || { echo "未找到 deb 包，编译可能异常"; }
EOF

# 执行 Docker 容器内编译
docker run --rm -i \
    --privileged \
    -e UBOOT_PACKAGE="${UBOOT_PACKAGE}" \
    -e UBOOT_RULES_TARGET="${UBOOT_RULES_TARGET}" \
    -e UBOOT_RULES_TARGET_EXTRA="${UBOOT_RULES_TARGET_EXTRA}" \
    -v "${HOST_UBOOT_ROOT}:/u-boot-build" \
    -v "${CONTAINER_SCRIPT}:/container-script.sh:ro" \
    -w /u-boot-build \
    "${DOCKER_IMAGE}" \
    /bin/bash /container-script.sh | tee /tmp/u-boot-build-container.log

# ===================== 第七步：清理与结果输出 =====================
# 清理临时文件
rm -f "${CONTAINER_SCRIPT}" /tmp/u-boot-build-container.log

# 输出编译结果路径
echo -e "\n===== U-Boot 构建完成 ===== 🚀"
echo "│ Ubuntu 版本: ${UBUNTU_VERSION}"
echo "│ U-Boot 包名: ${UBOOT_PACKAGE}"
echo "│ 产物路径: ${HOST_UBOOT_ROOT}/build/"
echo "│ 生成的 deb 包: "
ls -lh "${HOST_UBOOT_ROOT}/build/"*.deb || echo "  未找到 deb 包（编译可能异常）"
