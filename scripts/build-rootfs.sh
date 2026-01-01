#!/bin/bash
set -eE
trap 'echo "❌ 宿主机脚本异常退出"; exit 1' EXIT INT TERM QUIT

# ===================== 基础配置 =====================
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
YAML_FILE="${HOST_ROOTFS_ROOT}/definitions/tweaks.sh"  # 修正为实际tweaks.sh路径
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"
FINAL_TAR_PATH="${BUILD_DIR}/final/ubuntu-25.04-preinstalled-server.tar.xz"

# ===================== 前置检查 + 宿主机层面清理 =====================
if [ ! -f "${YAML_FILE}" ]; then
    echo "ERROR: YAML/tweaks.sh文件不存在 → ${YAML_FILE}" >&2
    exit 1
fi
rm -rf "${BUILD_DIR}"/*
mkdir -p "${BUILD_DIR}" "${BUILD_DIR}/img" "${BUILD_DIR}/final"

# ===================== 第一步：Docker Build（多线程编译 + 无多余注释） =====================
echo -e "\n=== 第一步：Docker Build 构建镜像 ==="
DOCKERFILE_DIR=$(mktemp -d)

cat > "${DOCKERFILE_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive

# ========== 换源逻辑（保留注释） ==========
RUN <<SCRIPT
set -e
# mkdir -p /etc/apt/backup
# cp /etc/apt/sources.list /etc/apt/backup/sources.list.bak 2>/dev/null || true
# cp /etc/apt/sources.list.d/* /etc/apt/backup/sources.list.d/ 2>/dev/null || true

# sed -i.bak 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
# sed -i 's@http://security.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
# if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
#    sed -i.bak 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources
#    sed -i 's@http://security.ubuntu.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources
# fi

# grep -E "mirrors.aliyun.com" /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
apt-get update -y -qq
SCRIPT

# ========== 安装依赖 + 多线程编译ubuntu-image ==========
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

# ===================== 第二步：Docker Run（tmpfs + trap清理 + inotify监控） =====================
echo -e "\n=== 第二步：Docker Run 构建Rootfs（tmpfs加速 + 自动清理） ==="
CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)

cat > "${CONTAINER_SCRIPT}" << 'SCRIPT_EOF'
#!/bin/bash
set -eE

# ===================== 核心：定义cleanup函数（清理tmpfs） =====================
cleanup() {
    echo -e "\n🔍 触发清理逻辑，卸载tmpfs..."
    # 安全卸载tmpfs（忽略卸载失败）
    if mount | grep -q "/rootfs-build/build type tmpfs"; then
        umount /rootfs-build/build || echo "⚠️ tmpfs卸载失败（可能已卸载）"
        echo "✅ tmpfs已成功卸载"
    fi
    # 清理残留进程
    pkill inotifywait || true
    echo "✅ 清理完成"
}

# ===================== 绑定信号：EXIT/INT/TERM/QUIT均触发cleanup =====================
trap 'cleanup' EXIT INT TERM QUIT

# ===================== 1. 初始化 + 挂载tmpfs =====================
# 清理旧目录
rm -rf /rootfs-build/build/*
mkdir -p /rootfs-build/build /rootfs-build/build/img /rootfs-build/build/final

# 挂载tmpfs（内存文件系统，加速IO）
echo "✅ 挂载tmpfs到/rootfs-build/build（size=4G）"
mount -t tmpfs -o size=4G,mode=755,uid=0,gid=0 tmpfs /rootfs-build/build

# ===================== 2. 修复tweaks.sh权限 + 属主 =====================
TWEAKS_FILE="/rootfs-build/definitions/tweaks.sh"
if [ -f "${TWEAKS_FILE}" ]; then
    chmod +x "${TWEAKS_FILE}"
    chown root:root "${TWEAKS_FILE}"
    echo "✅ 已修复tweaks.sh：执行权限(+x) + 属主(root:root)"
    ls -l "${TWEAKS_FILE}"
else
    echo "⚠️ 未找到tweaks.sh文件：${TWEAKS_FILE}"
fi

# ===================== 3. 配置binfmt（适配Ubuntu 25.04） =====================
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || true
update-binfmts --package qemu-user-static --install qemu-aarch64 /usr/bin/qemu-aarch64-static \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00' \
    --mask '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --fix-binary yes
update-binfmts --enable qemu-aarch64 || true
/usr/bin/qemu-aarch64-static --version || { echo "qemu-aarch64-static不存在"; exit 1; }

# ===================== 4. inotify内核级监控chroot创建 =====================
(
    inotifywait -m -r -e CREATE,ISDIR --format '%w%f' /rootfs-build/build | while read dir; do
        if [[ "$dir" == "/rootfs-build/build/chroot" ]]; then
            echo "✅ 内核检测到chroot目录创建，等待子目录初始化..."
            until [ -d "/rootfs-build/build/chroot/usr/bin" ]; do sleep 0.1; done
            cp /usr/bin/qemu-aarch64-static /rootfs-build/build/chroot/usr/bin/
            chmod +x /rootfs-build/build/chroot/usr/bin/qemu-aarch64-static
            echo "✅ qemu已复制到chroot，停止监控"
            pkill inotifywait
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# ===================== 5. 执行ubuntu-image =====================
echo "🚀 执行ubuntu-image构建..."
if ! ubuntu-image --debug \
    --workdir /rootfs-build/build \
    --output-dir /rootfs-build/build/img \
    classic /rootfs-build/definitions/ubuntu-rootfs-plucky.yaml; then  # 修正为实际YAML路径
  echo -e "\n❌ ubuntu-image执行失败，打印日志："
  [ -f "/rootfs-build/build/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap日志不存在"
  [ -f "/rootfs-build/build/img/build.log" ] && cat $_ || echo "ubuntu-image日志不存在"
  exit 1
fi

# ===================== 6. 等待监控进程 + 打包 =====================
if ps -p $MONITOR_PID > /dev/null; then
    wait $MONITOR_PID || true
fi

echo "📦 打包rootfs到tar.xz..."
tar -cJf /rootfs-build/build/final/ubuntu-25.04-preinstalled-server.tar.xz \
    -p -C /rootfs-build/build/chroot . \
    --sort=name \
    --xattrs

# 验证打包结果
ls -lh /rootfs-build/build/final/ubuntu-25.04-preinstalled-server.tar.xz
echo "🎉 构建成功！tmpfs清理将由trap自动触发"
SCRIPT_EOF

# 执行容器（--privileged确保挂载权限）
docker run --rm -i \
    --privileged \
    --cap-add=ALL \
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
    echo "========================================"
else
    echo -e "\n❌ 构建失败：未生成最终产物" >&2
    exit 1
fi

# 解除宿主机trap
trap - EXIT INT TERM QUIT
