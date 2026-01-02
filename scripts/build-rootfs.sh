#!/bin/bash
set -eE
trap 'echo "❌ 宿主机脚本异常退出"; exit 1' EXIT INT TERM QUIT

# ===================== 基础配置（YAML文件名由FLAVOR自动拼接） =====================
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"  # 磁盘构建/产物目录

# 固定目录（definitions目录路径统一）
DEFINITIONS_DIR_HOST="${HOST_ROOTFS_ROOT}/definitions"       # 宿主机definitions目录
DEFINITIONS_DIR_CONTAINER="/rootfs-build/definitions"        # 容器内definitions目录

# 检查父脚本导出的核心环境变量（仅需RELEASE_VERSION和FLAVOR）
REQUIRED_ENVS=("RELEASE_VERSION" "FLAVOR")
for env in "${REQUIRED_ENVS[@]}"; do
    if [ -z "${!env}" ]; then
        echo "ERROR: ${env}环境变量未定义！请从父脚本导出" >&2
        echo "示例：export RELEASE_VERSION=25.04; export FLAVOR=server" >&2
        exit 1
    fi
done

ls ./

echo "============分界线======="
mkdir -p build && cd build
ls ./

# 调试：打印关键信息（加到 if 前面）
echo "脚本执行目录：$(pwd)"
echo "RELASE_VERSION 变量值：${RELASE_VERSION:-未定义}"  # 未定义则显示“未定义”
echo "FLAVOR 变量值：${FLAVOR:-未定义}"
echo "拼接后的文件名：ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
# 调试：直接列出当前目录下的 ubuntu*rootfs.tar.xz 文件（看是否匹配）
ls -l ubuntu*rootfs.tar.xz 2>/dev/null || echo "当前目录无 ubuntu*rootfs.tar.xz 文件"

# 原逻辑
if [[ -f ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz ]]; then
    echo "found rootfs.tar.xz"
    exit 0
fi

# 自动拼接关键路径（核心：YAML文件名=ubuntu-rootfs-${FLAVOR}.yaml）
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
TWEAKS_FILE="${DEFINITIONS_DIR_HOST}/tweaks.sh"                     # 宿主机tweaks路径
YAML_CONFIG_FILENAME="ubuntu-rootfs-${FLAVOR}.yaml"                  # 自动拼接YAML文件名
YAML_CONFIG_FILE_HOST="${DEFINITIONS_DIR_HOST}/${YAML_CONFIG_FILENAME}"  # 宿主机YAML完整路径
YAML_CONFIG_FILE_CONTAINER="${DEFINITIONS_DIR_CONTAINER}/${YAML_CONFIG_FILENAME}"  # 容器内YAML完整路径

# ===================== 前置检查（确保文件存在） =====================
# 检查tweaks.sh
if [ ! -f "${TWEAKS_FILE}" ]; then
    echo "ERROR: tweaks.sh文件不存在 → ${TWEAKS_FILE}" >&2
    exit 1
fi

# 检查自动拼接后的YAML配置文件
if [ ! -f "${YAML_CONFIG_FILE_HOST}" ]; then
    echo "ERROR: YAML配置文件不存在 → ${YAML_CONFIG_FILE_HOST}" >&2
    echo "请确认FLAVOR=${FLAVOR}对应的YAML文件（${YAML_CONFIG_FILENAME}）存在于definitions目录" >&2
    exit 1
fi

# 清理旧产物和临时构建文件
rm -rf "${BUILD_DIR}/"*.tar.xz
rm -rf "${BUILD_DIR}/chroot" "${BUILD_DIR}/img"
mkdir -p "${BUILD_DIR}" "${BUILD_DIR}/img"

# ===================== 第一步：Docker Build（移除bc依赖） =====================
echo -e "\n=== 第一步：Docker Build 构建镜像 ==="
DOCKERFILE_DIR=$(mktemp -d)

cat > "${DOCKERFILE_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive

RUN <<SCRIPT
set -e
# 可选换源：
# sed -i.bak 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
apt-get update -y -qq
SCRIPT

# 安装通用依赖（移除bc）
RUN <<SCRIPT
set -e
apt-get install -y --no-install-recommends \
    debootstrap \
    schroot \
    qemu-user-static \
    binfmt-support \
    util-linux \
    mount \
    procps \
    apt-transport-https \
    ca-certificates \
    git \
    build-essential \
    devscripts \
    debhelper \
    rsync \
    xz-utils \
    curl \
    inotify-tools

tmp_dir=$(mktemp -d)
cd "${tmp_dir}" || exit 1
git clone --depth 1 https://github.com/canonical/ubuntu-image.git
cd ubuntu-image || exit 1
touch ubuntu-image.rst
apt-get build-dep . -y
dpkg-buildpackage -us -uc -j$(nproc)
apt-get install ../*.deb --assume-yes --allow-downgrades
dpkg -i ../*.deb
apt-mark hold ubuntu-image

cd /
rm -rf "${tmp_dir}"
command -v ubuntu-image || exit 1
SCRIPT

WORKDIR /rootfs-build
DOCKERFILE_EOF

# 构建镜像
docker build \
    --no-cache \
    --pull \
    --progress=plain \
    -t "${DOCKER_IMAGE}" \
    "${DOCKERFILE_DIR}"
rm -rf "${DOCKERFILE_DIR}"

# ===================== 第二步：Docker Run（容器内自动拼接YAML路径） =====================
echo -e "\n=== 第二步：Docker Run 构建Rootfs（纯磁盘目录） ==="
CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)

cat > "${CONTAINER_SCRIPT}" << 'SCRIPT_EOF'
#!/bin/bash
set -eE

# 配置参数（容器内固定目录）
BUILD_DIR="/rootfs-build/build"
DEFINITIONS_DIR_CONTAINER="/rootfs-build/definitions"

# 检查父脚本传递的环境变量（仅RELEASE_VERSION和FLAVOR）
REQUIRED_ENVS=("RELEASE_VERSION" "FLAVOR")
for env in "${REQUIRED_ENVS[@]}"; do
    if [ -z "${!env}" ]; then
        echo "ERROR: 容器内${env}环境变量未传递！" >&2
        exit 1
    fi
done

# 容器内自动拼接路径（核心：YAML文件名=ubuntu-rootfs-${FLAVOR}.yaml）
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
TWEAKS_FILE="${DEFINITIONS_DIR_CONTAINER}/tweaks.sh"
YAML_CONFIG_FILENAME="ubuntu-rootfs-${FLAVOR}.yaml"                  # 自动拼接YAML文件名
YAML_CONFIG_FILE="${DEFINITIONS_DIR_CONTAINER}/${YAML_CONFIG_FILENAME}"  # 容器内YAML完整路径

# ===================== 清理函数 =====================
cleanup() {
    echo -e "\n🔍 触发清理逻辑..."
    pkill inotifywait || true
    echo "✅ 清理完成（产物保留在${BUILD_DIR}）"
}
trap 'cleanup' EXIT INT TERM QUIT

# ===================== 修复tweaks.sh权限 =====================
if [ -f "$TWEAKS_FILE" ]; then
    chmod +x "$TWEAKS_FILE"
    chown root:root "$TWEAKS_FILE"
    echo "✅ 已修复tweaks.sh权限 → ${TWEAKS_FILE}"
else
    echo "ERROR: 容器内tweaks.sh不存在 → ${TWEAKS_FILE}" >&2
    exit 1
fi

# ===================== 检查容器内YAML文件 =====================
if [ ! -f "${YAML_CONFIG_FILE}" ]; then
    echo "ERROR: 容器内YAML配置文件不存在 → ${YAML_CONFIG_FILE}" >&2
    echo "请确认宿主机definitions目录包含${YAML_CONFIG_FILENAME}" >&2
    exit 1
fi

# ===================== 配置binfmt =====================
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || true
update-binfmts --package qemu-user-static --install qemu-aarch64 /usr/bin/qemu-aarch64-static \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00' \
    --mask '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --fix-binary yes
update-binfmts --enable qemu-aarch64 || true
/usr/bin/qemu-aarch64-static --version || { echo "qemu-aarch64-static不存在"; exit 1; }

# ===================== inotify监控chroot创建 =====================
(
    inotifywait -m -r -e CREATE,ISDIR --format '%w%f' "${BUILD_DIR}" | while read dir; do
        if [[ "$dir" == "${BUILD_DIR}/chroot" ]]; then
            echo "✅ 检测到chroot创建，等待子目录初始化..."
            until [ -d "${BUILD_DIR}/chroot/usr/bin" ]; do sleep 0.1; done
            cp /usr/bin/qemu-aarch64-static "${BUILD_DIR}/chroot/usr/bin/"
            chmod +x "${BUILD_DIR}/chroot/usr/bin/qemu-aarch64-static"
            echo "✅ qemu已复制到chroot"
            pkill inotifywait
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# ===================== 执行ubuntu-image（自动拼接的YAML路径） =====================
echo "🚀 执行ubuntu-image构建（YAML配置：${YAML_CONFIG_FILE}）..."
if ! ubuntu-image --debug \
    --workdir "${BUILD_DIR}" \
    --output-dir "${BUILD_DIR}/img" \
    classic "${YAML_CONFIG_FILE}"; then
  echo -e "\n❌ ubuntu-image执行失败"
  [ -f "${BUILD_DIR}/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap日志不存在"
  [ -f "${BUILD_DIR}/img/build.log" ] && cat $_ || echo "ubuntu-image日志不存在"
  exit 1
fi

# ===================== 打包产物 =====================
if ps -p $MONITOR_PID > /dev/null; then
    wait $MONITOR_PID || true
fi

echo "📦 打包rootfs（版本：${RELEASE_VERSION}，Flavor：${FLAVOR}）..."
tar -cJf ${FINAL_TAR_PATH} \
    -p -C "${BUILD_DIR}/chroot" . \
    --sort=name \
    --xattrs

# ===================== 验证产物 =====================
echo -e "\n🔍 产物验证："
ls -lh ${FINAL_TAR_PATH}
echo "🎉 构建成功！产物路径：${FINAL_TAR_PATH}"
SCRIPT_EOF

# 执行容器：仅传递RELEASE_VERSION和FLAVOR
docker run --rm -i \
    --privileged \
    --cap-add=ALL \
    -e RELEASE_VERSION="${RELEASE_VERSION}" \
    -e FLAVOR="${FLAVOR}" \
    -v "${HOST_ROOTFS_ROOT}:/rootfs-build" \
    -v "${BUILD_DIR}:/rootfs-build/build" \
    -v "${CONTAINER_SCRIPT}:/tmp/run-script.sh:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /tmp/run-script.sh

# 清理容器脚本
rm -f "${CONTAINER_SCRIPT}"

# ===================== 宿主机验证 =====================
set +x
if [ -f "${FINAL_TAR_PATH}" ]; then
    echo -e "\n========================================"
    echo "🎉 整体构建成功！"
    echo "📁 产物路径：${FINAL_TAR_PATH}"
    echo "📏 产物大小：$(du -sh "${FINAL_TAR_PATH}" | awk '{print $1}')"
    echo "✅ 版本：${RELEASE_VERSION} | Flavor：${FLAVOR} | YAML：${YAML_CONFIG_FILENAME}"
    echo "========================================"
else
    echo -e "\n❌ 构建失败：未生成产物" >&2
    ls -la "${BUILD_DIR}/"
    exit 1
fi

# 解除trap
trap - EXIT INT TERM QUIT
