#!/bin/bash
set -eE
trap 'echo "❌ 宿主机脚本异常退出"; exit 1' EXIT INT TERM QUIT

# ===================== 基础配置（仅保留核心参数） =====================
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
YAML_FILE="${HOST_ROOTFS_ROOT}/definitions/tweaks.sh"
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"  # 磁盘构建/产物目录

# 检查SUITE是否由父脚本导出
if [ -z "${SUITE}" ]; then
    echo "ERROR: SUITE环境变量未定义！请从父脚本导出（如export SUITE=server）" >&2
    exit 1
fi

# 产物路径（磁盘目录，无tmpfs影响）
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-25.04-preinstalled-${SUITE}-arm64.rootfs.tar.xz"

# ===================== 前置检查 + 清理旧产物 =====================
if [ ! -f "${YAML_FILE}" ]; then
    echo "ERROR: tweaks.sh文件不存在 → ${YAML_FILE}" >&2
    exit 1
fi
# 清理旧产物，保留目录结构
rm -rf "${BUILD_DIR}/"*.tar.xz
rm -rf "${BUILD_DIR}/chroot" "${BUILD_DIR}/img"
mkdir -p "${BUILD_DIR}" "${BUILD_DIR}/img"

# ===================== 第一步：Docker Build（无多余注释） =====================
echo -e "\n=== 第一步：Docker Build 构建镜像 ==="
DOCKERFILE_DIR=$(mktemp -d)

cat > "${DOCKERFILE_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive

RUN <<SCRIPT
set -e
# 换源逻辑（保留必要注释）
# sed -i.bak 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
# sed -i 's@http://security.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
apt-get update -y -qq
SCRIPT

# 安装依赖（包含bc，无tmpfs相关）
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
    python3-all \
    python3-setuptools \
    python3-wheel \
    python3-pip \
    rsync \
    xz-utils \
    curl \
    inotify-tools \
    bc

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

# ===================== 第二步：Docker Run（纯磁盘构建，无tmpfs） =====================
echo -e "\n=== 第二步：Docker Run 构建Rootfs（纯磁盘目录） ==="
CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)

cat > "${CONTAINER_SCRIPT}" << 'SCRIPT_EOF'
#!/bin/bash
set -eE

# 配置参数（无tmpfs相关）
BUILD_DIR="/rootfs-build/build"  # 磁盘构建/产物目录

# 检查SUITE环境变量
if [ -z "${SUITE}" ]; then
    echo "ERROR: 容器内SUITE环境变量未传递！" >&2
    exit 1
fi
# 产物路径（磁盘目录）
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-25.04-preinstalled-${SUITE}-arm64.rootfs.tar.xz"

# ===================== 简化清理函数（仅清理进程） =====================
cleanup() {
    echo -e "\n🔍 触发清理逻辑..."
    # 仅清理inotifywait残留进程
    pkill inotifywait || true
    echo "✅ 清理完成（产物保留在${BUILD_DIR}）"
}

# 绑定信号
trap 'cleanup' EXIT INT TERM QUIT

# ===================== 修复tweaks.sh权限 =====================
TWEAKS_FILE="/rootfs-build/definitions/tweaks.sh"
if [ -f "$TWEAKS_FILE" ]; then
    chmod +x "$TWEAKS_FILE"
    chown root:root "$TWEAKS_FILE"
    echo "✅ 已修复tweaks.sh权限"
    ls -l "$TWEAKS_FILE"
else
    echo "⚠️ 未找到tweaks.sh文件：$TWEAKS_FILE"
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

# ===================== inotify监控chroot创建（磁盘目录） =====================
(
    inotifywait -m -r -e CREATE,ISDIR --format '%w%f' "${BUILD_DIR}" | while read dir; do
        if [[ "$dir" == "${BUILD_DIR}/chroot" ]]; then
            echo "✅ 检测到chroot创建（磁盘目录），等待子目录初始化..."
            until [ -d "${BUILD_DIR}/chroot/usr/bin" ]; do sleep 0.1; done
            cp /usr/bin/qemu-aarch64-static "${BUILD_DIR}/chroot/usr/bin/"
            chmod +x "${BUILD_DIR}/chroot/usr/bin/qemu-aarch64-static"
            echo "✅ qemu已复制到chroot（磁盘目录）"
            pkill inotifywait
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# ===================== 执行ubuntu-image（磁盘目录构建） =====================
echo "🚀 执行ubuntu-image构建（磁盘目录：${BUILD_DIR}）..."
if ! ubuntu-image --debug \
    --workdir "${BUILD_DIR}" \
    --output-dir "${BUILD_DIR}/img" \
    classic /rootfs-build/definitions/ubuntu-rootfs-plucky.yaml; then
  echo -e "\n❌ ubuntu-image执行失败"
  [ -f "${BUILD_DIR}/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap日志不存在"
  [ -f "${BUILD_DIR}/img/build.log" ] && cat $_ || echo "ubuntu-image日志不存在"
  exit 1
fi

# ===================== 等待监控进程 + 打包（产物输出到磁盘） =====================
if ps -p $MONITOR_PID > /dev/null; then
    wait $MONITOR_PID || true
fi

echo "📦 打包rootfs到磁盘产物目录..."
tar -cJf ${FINAL_TAR_PATH} \
    -p -C "${BUILD_DIR}/chroot" . \
    --sort=name \
    --xattrs

# ===================== 验证产物（磁盘目录） =====================
echo -e "\n🔍 验证产物（磁盘目录）："
ls -lh ${FINAL_TAR_PATH}
echo "🎉 构建成功！产物已保存到磁盘：${FINAL_TAR_PATH}"
SCRIPT_EOF

# 执行容器：传递SUITE，绑定磁盘构建/产物目录
docker run --rm -i \
    --privileged \
    --cap-add=ALL \
    -e SUITE="${SUITE}" \
    -v "${HOST_ROOTFS_ROOT}:/rootfs-build" \
    -v "${BUILD_DIR}:/rootfs-build/build" \
    -v "${CONTAINER_SCRIPT}:/tmp/run-script.sh:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /tmp/run-script.sh

# 清理容器脚本
rm -f "${CONTAINER_SCRIPT}"

# ===================== 宿主机验证（产物在磁盘） =====================
set +x
if [ -f "${FINAL_TAR_PATH}" ]; then
    echo -e "\n========================================"
    echo "🎉 整体构建成功！"
    echo "📁 产物路径（磁盘）：${FINAL_TAR_PATH}"
    echo "📏 产物大小：$(du -sh "${FINAL_TAR_PATH}" | awk '{print $1}')"
    echo "✅ SUITE：${SUITE}"
    echo "✅ 产物永久保存在磁盘，无tmpfs丢失风险"
    echo "========================================"
else
    echo -e "\n❌ 构建失败：未生成最终产物" >&2
    ls -la "${BUILD_DIR}/"
    exit 1
fi

# 解除宿主机trap
trap - EXIT INT TERM QUIT
