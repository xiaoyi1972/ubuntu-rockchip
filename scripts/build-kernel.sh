#!/bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# ===================== 第一步：Docker 环境初始化 + 动态版本解析 =====================
# 定义 Docker 镜像名称（与 U-Boot 共用，保证版本一致）
DOCKER_IMAGE="ubuntu-kernel-u-boot-build:dynamic"

# 修复：更稳定的路径解析（兼容 WSL/原生 Linux，添加调试输出）
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
HOST_KERNEL_ROOT=$(realpath "${SCRIPT_DIR}/.." 2>/dev/null)
# 调试：输出路径信息（便于移植时排查）
echo "===== 路径调试信息 ====="
echo "脚本绝对路径: ${SCRIPT_PATH}"
echo "脚本所在目录: ${SCRIPT_DIR}"
echo "内核构建根目录: ${HOST_KERNEL_ROOT}"

# 国内 Ubuntu 镜像仓库（兼容多源，优先网易）
UBUNTU_MIRROR="hub-mirror.c.163.com/library/ubuntu"

# 检查 SUITE 是否设置
if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set (e.g. export SUITE=plucky)"
    exit 1
fi

# 加载 Suite 配置文件（如 plucky.sh）
SUITE_CONFIG_FILE="${HOST_KERNEL_ROOT}/config/suites/${SUITE}.sh"
if [ ! -f "${SUITE_CONFIG_FILE}" ]; then
    echo "Error: Suite 配置文件不存在 → ${SUITE_CONFIG_FILE}"
    exit 1
fi
# shellcheck source=/dev/null
source "${SUITE_CONFIG_FILE}"

# 提取 Ubuntu 版本（从 plucky.sh 的 RELEASE_VERSION）
UBUNTU_VERSION="${RELEASE_VERSION}"
# 关键修复1：加强 UBUNTU_VERSION 非空校验
if [ -z "${UBUNTU_VERSION}" ]; then
    echo "Error: RELEASE_VERSION 未在 ${SUITE_CONFIG_FILE} 中定义，或值为空"
    echo "请检查 ${SUITE_CONFIG_FILE} 中是否有类似：RELEASE_VERSION=\"25.04\""
    exit 1
fi
# 调试输出：确认变量赋值
echo "===== 核心变量校验 ====="
echo "SUITE: ${SUITE}"
echo "RELEASE_VERSION (从配置文件读取): ${RELEASE_VERSION}"
echo "UBUNTU_VERSION: ${UBUNTU_VERSION}"

# ===================== Docker 权限修复（保留，增加兼容性处理） =====================
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

    # 修复 Docker 套接字权限（兼容不同环境）
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

# ===================== 基础检查 =====================
# 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo "===== 安装 Docker 环境 ====="
    apt-get update && apt-get install -y --no-install-recommends docker.io
    if [ -n "${SUDO_USER}" ]; then
        usermod -aG docker "${SUDO_USER}" || true
        newgrp docker &> /dev/null
    fi
fi

# 修复 Docker 权限（保留核心逻辑）
fix_docker_permission

# ===================== 动态查询 GCC 版本（优化 debconf 警告） =====================
echo "===== 解析配置 ====="
echo "Suite: ${SUITE}"
echo "Ubuntu 版本: ${UBUNTU_VERSION}"
echo "内核分支: ${KERNEL_BRANCH:-未定义}"
echo "内核仓库: ${KERNEL_REPO:-未定义}"

# 自动查询 GCC 版本（添加 debconf 非交互环境变量）
EXPECTED_GCC_VERSION=$(docker run --rm --entrypoint /bin/bash \
    -e DEBIAN_FRONTEND=noninteractive \
    -e DEBCONF_NONINTERACTIVE_SEEN=true \
    ubuntu:"${UBUNTU_VERSION}" -c "
    apt-get update -qq >/dev/null && 
    apt-get install -qq --no-install-recommends gcc -y >/dev/null && 
    gcc --version | head -1 | awk '{print \$4}' | sed 's/)//'
")
if [ -z "${EXPECTED_GCC_VERSION}" ]; then
    echo "Error: 无法获取 Ubuntu ${UBUNTU_VERSION} 的 GCC 版本"
    exit 1
fi
echo "Ubuntu ${UBUNTU_VERSION} 默认 GCC 版本: ${EXPECTED_GCC_VERSION}"

# ===================== 构建 Docker 镜像（HEREDOC 内联脚本，无临时文件/转义符） =====================
if ! docker images | grep -q "${DOCKER_IMAGE}"; then
    echo "===== 构建 Docker 镜像 ====="
    # 验证构建上下文路径存在
    if [ ! -d "${HOST_KERNEL_ROOT}" ]; then
        echo "Error: 构建上下文路径不存在 → ${HOST_KERNEL_ROOT}"
        exit 1
    fi

    # 生成 Dockerfile（HEREDOC 内联所有复杂逻辑，无转义符/临时脚本）
    TEMP_DOCKERFILE=$(mktemp)
    echo "调试：临时 Dockerfile 路径 = ${TEMP_DOCKERFILE}"
    cat > "${TEMP_DOCKERFILE}" << EOF
# 定义 ARG（必须在 FROM 前）
ARG UBUNTU_VERSION=25.04
# 基础镜像
FROM public.ecr.aws/ubuntu/ubuntu:\${UBUNTU_VERSION}
# FROM ubuntu:\${UBUNTU_VERSION}

# 定义容器内需要的 ARG
ARG UBUNTU_VERSION
ARG EXPECTED_GCC_VERSION

# 全局环境变量（消除交互警告）
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
ENV LANG=C.UTF-8
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 核心：HEREDOC 内联脚本（无转义符，直接写标准 Shell）
RUN <<SCRIPT
#!/bin/bash
set -eE
trap 'echo "环境构建错误: 行号 \$LINENO"; exit 1' ERR

# 安装依赖（容错：升级失败不中断）
apt-get update && \
apt-get upgrade -y || true && \
apt-get install -y --no-install-recommends \
lsb-release \
debhelper fakeroot build-essential dpkg-dev devscripts \
bc bison flex libssl-dev libncurses-dev libelf-dev dwarves \
gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
git wget libterm-readline-gnu-perl \
gawk cpio && \
echo "安装后检查 gawk 路径：" && \
which gawk || (echo "gawk 安装后未找到，重新安装" && apt-get install -y --reinstall gawk) && \
apt-get clean && rm -rf /var/lib/apt/lists/*

# 校验 Ubuntu 版本
ACTUAL_UBUNTU_VERSION=\$(lsb_release -rs)
echo "容器内 Ubuntu 版本: \$ACTUAL_UBUNTU_VERSION"
echo "预期 Ubuntu 版本: \$UBUNTU_VERSION"
if [ "\$ACTUAL_UBUNTU_VERSION" != "\$UBUNTU_VERSION" ]; then
    echo "版本不匹配：预期 \$UBUNTU_VERSION，实际 \$ACTUAL_UBUNTU_VERSION"
    exit 1
fi

# 校验 GCC 版本
ACTUAL_GCC_VERSION=\$(gcc --version | head -1 | awk '{print \$4}' | sed 's/)//')
echo "容器内 GCC 版本: \$ACTUAL_GCC_VERSION"
echo "预期 GCC 版本: \$EXPECTED_GCC_VERSION"
if [ "\$ACTUAL_GCC_VERSION" != "\$EXPECTED_GCC_VERSION" ]; then
    echo "版本不匹配：预期 \$EXPECTED_GCC_VERSION，实际 \$ACTUAL_GCC_VERSION"
    exit 1
fi

# 增强 gawk 校验（无转义符，直接写逻辑）
echo "===== 调试 gawk 安装 ====="
echo "当前 PATH: \$PATH"
ls -l /usr/bin/gawk* || true

# 检查 gawk 可执行性
if [ ! -x "/usr/bin/gawk" ]; then
    echo "Error: gawk 可执行文件不存在/不可执行"
    echo "文件信息: " && stat /usr/bin/gawk || true
    echo "已安装包信息: " && dpkg -l gawk
    exit 1
else
    echo "gawk 安装成功，版本: \$(gawk --version | head -1)"
    echo "gawk 路径: \$(which gawk)"
    echo "gawk 功能测试: \$(echo '1+1' | gawk '{print \$1}')"
fi
SCRIPT

# 设置工作目录
WORKDIR /kernel-build
EOF

    # 执行 Docker 构建（仅传递 ARG，无其他依赖）
    echo "===== 执行 Docker Build ====="
    echo "传递参数："
    echo "  --build-arg UBUNTU_VERSION=${UBUNTU_VERSION}"
    echo "  --build-arg EXPECTED_GCC_VERSION=${EXPECTED_GCC_VERSION}"
    echo "  上下文路径: ${HOST_KERNEL_ROOT}"
    echo "  Dockerfile 路径: ${TEMP_DOCKERFILE}"

    docker build \
        --no-cache \
        --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
        --build-arg EXPECTED_GCC_VERSION="${EXPECTED_GCC_VERSION}" \
        -t "${DOCKER_IMAGE}" \
        -f "${TEMP_DOCKERFILE}" \
        "${HOST_KERNEL_ROOT}"

    # 仅清理临时 Dockerfile（无其他临时文件）
    rm -f "${TEMP_DOCKERFILE}"
else
    echo "Docker 镜像已存在，跳过构建步骤"
fi

# ===================== 容器内构建内核（逻辑不变，无临时脚本） =====================
echo "===== 启动容器构建内核 ====="

# 临时文件仅用于容器内编译脚本（若想彻底无临时文件，可改用 heredoc 传入容器，见补充说明）
CONTAINER_SCRIPT=$(mktemp)
cat > "${CONTAINER_SCRIPT}" << 'EOF'
#!/bin/bash
set -eE
trap 'echo "容器内错误: 行号 $LINENO"; exit 1' ERR

# 调试：输出容器内环境变量
echo "===== 容器内环境变量 ====="
echo "SUITE: ${SUITE}"
echo "KERNEL_REPO: ${KERNEL_REPO}"
echo "KERNEL_BRANCH: ${KERNEL_BRANCH}"
echo "KERNEL_FLAVOR: ${KERNEL_FLAVOR}"
echo "当前目录: $(pwd)"
echo "目录内容: $(ls -la)"

# 核心修复：容器内强制安装 gawk（双重保障）
echo "===== 容器内安装 gawk 依赖 ====="
apt-get install -y --no-install-recommends gawk || { echo "gawk 安装失败"; exit 1; }
# 替换为可靠的文件可执行性检查
if [ ! -x "/usr/bin/gawk" ]; then
    echo "Error: 容器内 gawk 安装后仍无法找到或不可执行"
    echo "PATH: $PATH"
    ls -l /usr/bin/gawk* || true
    stat /usr/bin/gawk || true
    exit 1
fi
echo "容器内 gawk 版本: $(gawk --version | head -1)"
echo "容器内 gawk 路径: $(which gawk)"
echo "容器内 gawk 功能测试: $(echo '2+2' | gawk '{print $1}')"

command -v modinfo || { echo "Error: modinfo (kmod) 未安装"; exit 1; }  # 添加
command -v depmod || { echo "Error: depmod (kmod) 未安装"; exit 1; }    # 添加

echo "✓ modinfo: $(which modinfo)"
echo "✓ depmod: $(which depmod)"

# 修复 Git 克隆逻辑：先检查目录是否存在，不存在则克隆，存在则拉取
echo "===== 克隆/更新内核源码 ====="
mkdir -p build && cd build || { echo "进入 build 目录失败"; exit 1; }

# 检查仓库是否可访问
echo "测试仓库可访问性: git ls-remote ${KERNEL_REPO} ${KERNEL_BRANCH}"
git ls-remote "${KERNEL_REPO}" "${KERNEL_BRANCH}" || { echo "仓库/分支不可访问"; exit 1; }

if [ -d "linux-rockchip/.git" ]; then
    echo "源码目录已存在，执行 pull 更新"
    git -C linux-rockchip pull --depth=2 || { 
        echo "Git pull 失败，尝试重新克隆"; 
        rm -rf linux-rockchip; 
    }
fi

if [ ! -d "linux-rockchip/.git" ]; then
    echo "源码目录不存在，克隆仓库"
    git clone --progress -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip --depth=2 || { 
        echo "Git 克隆失败"; 
        exit 1; 
    }
fi

cd linux-rockchip || { echo "进入 linux-rockchip 目录失败"; exit 1; }
git checkout "${KERNEL_BRANCH}" || { echo "切换分支失败"; exit 1; }
echo "当前分支: $(git rev-parse --abbrev-ref HEAD)"
echo "最新提交: $(git log -1 --oneline)"

# 检查是否存在 debian/rules
echo "===== 检查编译配置文件 ====="
if [ ! -f "debian/rules" ]; then
    echo "Error: 源码目录中未找到 debian/rules 文件"
    echo "当前目录文件: $(ls -la debian/ | head -20)"
    exit 1
fi

# 提取内核版本
echo "===== 提取内核版本 ====="
KERNEL_VER=$(make -s kernelversion) || { echo "提取内核版本失败"; exit 1; }
echo "内核源码版本: ${KERNEL_VER}"

# 编译前检查依赖
echo "===== 检查编译依赖 ====="
dpkg-architecture -aarm64 || { echo "dpkg-architecture 执行失败"; exit 1; }
which aarch64-linux-gnu-gcc || { echo "未找到 aarch64-linux-gnu-gcc"; exit 1; }
aarch64-linux-gnu-gcc --version

# 编译内核：添加详细输出，重定向错误到标准输出
echo "===== 开始编译内核 ====="
export $(dpkg-architecture -aarm64)
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=aarch64-linux-gnu-gcc
export LANG=C

echo "执行: fakeroot debian/rules clean"
fakeroot debian/rules clean 2>&1 || { echo "clean 步骤失败"; exit 1; }

echo "执行: fakeroot debian/rules binary-headers binary-rockchip do_mainline_build=true"
fakeroot debian/rules binary-headers binary-rockchip do_mainline_build=true 2>&1 || { 
    echo "编译内核失败"; 
    exit 1; 
}

# 输出内核版本（供外部捕获）
echo "===== 编译完成，内核版本 ====="
echo "${KERNEL_VER}"
EOF

# 执行容器内编译
docker run --rm -i \
    --privileged \
    -e SUITE="${SUITE}" \
    -e RELEASE_VERSION="${UBUNTU_VERSION}" \
    -e KERNEL_REPO="${KERNEL_REPO}" \
    -e KERNEL_BRANCH="${KERNEL_BRANCH}" \
    -e KERNEL_FLAVOR="${KERNEL_FLAVOR}" \
    -v "${HOST_KERNEL_ROOT}:/kernel-build" \
    -v "${CONTAINER_SCRIPT}:/container-script.sh:ro" \
    -w /kernel-build \
    "${DOCKER_IMAGE}" \
    /bin/bash /container-script.sh | tee /tmp/kernel-build-container.log

# 提取内核版本并清理临时文件
KERNEL_VERSION=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+" /tmp/kernel-build-container.log | tail -1)
rm -f "${CONTAINER_SCRIPT}" /tmp/kernel-build-container.log

# 检查内核版本是否获取成功
if [ -z "${KERNEL_VERSION}" ]; then
    echo "Error: 未获取到内核版本，编译过程可能失败"
    exit 1
fi

# ===================== 构建完成：输出汇总信息 =====================
echo -e "\n===== 内核构建完成 ===== 🚀"
echo "│ Ubuntu 版本  ${UBUNTU_VERSION}"
echo "│ GCC 构建版本  ${EXPECTED_GCC_VERSION}"
echo "│ 内核源码版本  ${KERNEL_VERSION}"
echo "│ 内核分支  ${KERNEL_BRANCH}"
echo "│ 产物路径  ${HOST_KERNEL_ROOT}/build/"
