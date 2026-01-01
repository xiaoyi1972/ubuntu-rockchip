#!/bin/bash
set -eE
trap 'echo "❌ 宿主机脚本异常退出"; exit 1' EXIT INT TERM QUIT

# ===================== 基础配置（使用父脚本导出的SUITE环境变量） =====================
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
YAML_FILE="${HOST_ROOTFS_ROOT}/definitions/tweaks.sh"
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"  # 宿主机磁盘目录（存产物）

# 检查SUITE是否由父脚本导出
if [ -z "${SUITE}" ]; then
    echo "ERROR: SUITE环境变量未定义！请从父脚本导出（如export SUITE=server）" >&2
    exit 1
fi

# 产物路径：宿主机磁盘目录（不受tmpfs影响）
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-25.04-preinstalled-${SUITE}-arm64.rootfs.tar.xz"
TMPFS_SIZE="8G"
MEM_THRESHOLD_GB=8
# 容器内临时构建目录（挂载tmpfs）
CONTAINER_TMP_DIR="/rootfs-build/build_tmp"

# ===================== 前置检查 + 清理 =====================
if [ ! -f "${YAML_FILE}" ]; then
    echo "ERROR: tweaks.sh文件不存在 → ${YAML_FILE}" >&2
    exit 1
fi
# 仅清理产物目录的旧文件，保留目录结构
rm -rf "${BUILD_DIR}/"*.tar.xz
mkdir -p "${BUILD_DIR}"

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

# 安装依赖（包含bc，无多余注释）
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

# ===================== 第二步：Docker Run（分离tmpfs和产物目录） =====================
echo -e "\n=== 第二步：Docker Run 构建Rootfs（智能tmpfs适配） ==="
CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)

cat > "${CONTAINER_SCRIPT}" << 'SCRIPT_EOF'
#!/bin/bash
set -eE

# 配置参数
TMPFS_SIZE="8G"
MEM_THRESHOLD_GB=8
USE_TMPFS=true
CONTAINER_TMP_DIR="/rootfs-build/build_tmp"  # 临时构建目录（tmpfs）
CONTAINER_OUTPUT_DIR="/rootfs-build/build"   # 产物目录（宿主机磁盘）

# 检查SUITE环境变量
if [ -z "${SUITE}" ]; then
    echo "ERROR: 容器内SUITE环境变量未传递！" >&2
    exit 1
fi
# 产物路径：输出到宿主机磁盘目录（不受tmpfs影响）
FINAL_TAR_PATH="${CONTAINER_OUTPUT_DIR}/ubuntu-25.04-preinstalled-${SUITE}-arm64.rootfs.tar.xz"

# ===================== 核心修复：清理函数仅卸载临时tmpfs，保留产物 =====================
cleanup() {
    echo -e "\n🔍 触发清理逻辑..."
    # 仅卸载临时构建目录的tmpfs，产物目录不受影响
    if [ "$USE_TMPFS" = true ] && mount | grep -q "${CONTAINER_TMP_DIR} type tmpfs"; then
        umount "${CONTAINER_TMP_DIR}" || echo "⚠️ 临时tmpfs卸载失败（可能已卸载）"
        echo "✅ 临时构建目录tmpfs已成功卸载"
    fi
    # 清理残留进程
    pkill inotifywait || true
    # 清理临时目录（可选，产物已在磁盘）
    rm -rf "${CONTAINER_TMP_DIR}" || true
    echo "✅ 清理完成（产物保留在${CONTAINER_OUTPUT_DIR}）"
}

# 绑定信号
trap 'cleanup' EXIT INT TERM QUIT

# ===================== 内存检查 =====================
echo "📊 检查系统内存..."
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$(echo "scale=1; $TOTAL_MEM_KB / 1024 / 1024" | bc)
echo "系统总内存：${TOTAL_MEM_GB}G，阈值：${MEM_THRESHOLD_GB}G"

if (( $(echo "$TOTAL_MEM_GB < $MEM_THRESHOLD_GB" | bc -l) )); then
    echo "⚠️ 内存不足，禁用tmpfs（使用磁盘临时目录）"
    USE_TMPFS=false
else
    echo "✅ 内存充足，启用${TMPFS_SIZE} tmpfs（仅用于临时构建）"
fi

# ===================== 初始化目录 =====================
# 清理并创建临时构建目录
rm -rf "${CONTAINER_TMP_DIR}"
mkdir -p "${CONTAINER_TMP_DIR}" "${CONTAINER_TMP_DIR}/img"
# 确保产物目录存在（宿主机磁盘）
mkdir -p "${CONTAINER_OUTPUT_DIR}"

# ===================== 挂载tmpfs（仅临时目录） =====================
if [ "$USE_TMPFS" = true ]; then
    mount -t tmpfs -o size=${TMPFS_SIZE},mode=755,uid=0,gid=0 tmpfs "${CONTAINER_TMP_DIR}"
    echo "✅ tmpfs已挂载到临时目录：${CONTAINER_TMP_DIR}"
else
    echo "📁 使用磁盘临时目录：${CONTAINER_TMP_DIR}"
fi

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

# ===================== inotify监控临时目录的chroot创建 =====================
(
    inotifywait -m -r -e CREATE,ISDIR --format '%w%f' "${CONTAINER_TMP_DIR}" | while read dir; do
        if [[ "$dir" == "${CONTAINER_TMP_DIR}/chroot" ]]; then
            echo "✅ 检测到chroot创建（临时目录），等待子目录初始化..."
            until [ -d "${CONTAINER_TMP_DIR}/chroot/usr/bin" ]; do sleep 0.1; done
            cp /usr/bin/qemu-aarch64-static "${CONTAINER_TMP_DIR}/chroot/usr/bin/"
            chmod +x "${CONTAINER_TMP_DIR}/chroot/usr/bin/qemu-aarch64-static"
            echo "✅ qemu已复制到chroot（临时目录）"
            pkill inotifywait
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# ===================== 执行ubuntu-image（临时目录构建） =====================
echo "🚀 执行ubuntu-image构建（临时目录：${CONTAINER_TMP_DIR}）..."
if ! ubuntu-image --debug \
    --workdir "${CONTAINER_TMP_DIR}" \
    --output-dir "${CONTAINER_TMP_DIR}/img" \
    classic /rootfs-build/definitions/ubuntu-rootfs-plucky.yaml; then
  echo -e "\n❌ ubuntu-image执行失败"
  [ -f "${CONTAINER_TMP_DIR}/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap日志不存在"
  [ -f "${CONTAINER_TMP_DIR}/img/build.log" ] && cat $_ || echo "ubuntu-image日志不存在"
  exit 1
fi

# ===================== 等待监控进程 + 打包（产物输出到磁盘） =====================
if ps -p $MONITOR_PID > /dev/null; then
    wait $MONITOR_PID || true
fi

echo "📦 打包rootfs到磁盘产物目录..."
tar -cJf ${FINAL_TAR_PATH} \
    -p -C "${CONTAINER_TMP_DIR}/chroot" . \
    --sort=name \
    --xattrs

# ===================== 验证产物（磁盘目录） =====================
echo -e "\n🔍 验证产物（磁盘目录）："
ls -lh ${FINAL_TAR_PATH}
echo "🎉 构建成功！产物已保存到磁盘：${FINAL_TAR_PATH}"
echo "⚠️ 后续清理仅删除临时构建目录，产物不受影响"
SCRIPT_EOF

# 执行容器：传递SUITE，绑定产物目录（磁盘）
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
    echo "✅ 产物已保存到磁盘，不受tmpfs清理影响"
    echo "========================================"
else
    echo -e "\n❌ 构建失败：未生成最终产物" >&2
    ls -la "${BUILD_DIR}/"
    exit 1
fi

# 解除宿主机trap
trap - EXIT INT TERM QUIT
