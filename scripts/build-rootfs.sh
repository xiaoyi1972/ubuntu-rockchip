#!/bin/bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR
set -x

# ===================== 基础配置 =====================
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
YAML_FILE="${HOST_ROOTFS_ROOT}/definitions/ubuntu-rootfs-plucky.yaml"
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"
FINAL_TAR_PATH="${BUILD_DIR}/final/ubuntu-25.04-preinstalled-server.tar.xz"

# ===================== 前置检查 + 宿主机层面清理chroot =====================
if [ ! -f "${YAML_FILE}" ]; then
    echo "ERROR: YAML配置文件不存在 → ${YAML_FILE}" >&2
    exit 1
fi
# 仅删除，不创建chroot
rm -rf "${BUILD_DIR}/chroot"
mkdir -p "${BUILD_DIR}" "${BUILD_DIR}/img" "${BUILD_DIR}/final"

# ===================== 第一步：Docker Build（删除注释 + 多线程编译） =====================
echo -e "\n=== 第一步：Docker Build 构建镜像 ==="
DOCKERFILE_DIR=$(mktemp -d)

cat > "${DOCKERFILE_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive

# ========== 保留换源逻辑 ==========
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

# ========== 安装依赖 + 多线程编译ubuntu-image（删除所有行内注释） ==========
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

# 执行Docker Build
docker build \
    --no-cache \
    --pull \
    --progress=plain \
    -t "${DOCKER_IMAGE}" \
    "${DOCKERFILE_DIR}"
rm -rf "${DOCKERFILE_DIR}"

# ===================== 第二步：Docker Run（替换为指定的inotify逻辑） =====================
echo -e "\n=== 第二步：Docker Run 构建Rootfs ==="
CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)

cat > "${CONTAINER_SCRIPT}" << 'SCRIPT_EOF'
set -e
# 仅清理，不创建chroot
rm -rf /rootfs-build/build/chroot/* || true
rm -rf /rootfs-build/build/chroot || true

# ===================== 核心修复：权限+用户组（移到外层） =====================
TWEAKS_FILE="/rootfs-build/definitions/tweaks.sh"
if [ -f "${TWEAKS_FILE}" ]; then
    # 1. 修复执行权限
    chmod +x "${TWEAKS_FILE}"
    # 2. 修复属主/属组（关键：确保chroot内root能访问）
    chown root:root "${TWEAKS_FILE}"
    echo "✅ 已修复tweaks.sh：执行权限(+x) + 属主(root:root)"
    # 验证权限和属主
    ls -l "${TWEAKS_FILE}"
else
    echo "⚠️ 未找到tweaks.sh文件：${TWEAKS_FILE}"
fi

# 关键修复1：配置binfmt（适配Ubuntu 25.04）
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || true
update-binfmts --package qemu-user-static --install qemu-aarch64 /usr/bin/qemu-aarch64-static \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00' \
    --mask '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --fix-binary yes
update-binfmts --enable qemu-aarch64 || true
/usr/bin/qemu-aarch64-static --version || { echo "qemu-aarch64-static不存在"; exit 1; }

# 关键修复2：替换为指定的inotify监控逻辑
# 等待chroot目录创建（内核事件触发，无轮询）
(
    inotifywait -m -r -e CREATE,ISDIR --format '%w%f' /rootfs-build/build | while read dir; do
        # 检测是否是chroot目录创建
        if [[ "$dir" == "/rootfs-build/build/chroot" ]]; then
            echo "✅ 内核检测到chroot目录创建，等待子目录初始化..."
            # 等待chroot/usr/bin创建（debootstrap会初始化目录结构）
            until [ -d "/rootfs-build/build/chroot/usr/bin" ]; do sleep 0.1; done
            # 复制qemu到chroot（解决/bin/true执行失败）
            cp /usr/bin/qemu-aarch64-static /rootfs-build/build/chroot/usr/bin/
            chmod +x /rootfs-build/build/chroot/usr/bin/qemu-aarch64-static
            echo "✅ qemu已复制到chroot，停止监控"
            # 停止inotify监控（避免僵尸进程）
            pkill inotifywait
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# 执行ubuntu-image（YAML内的逻辑由其自行处理）
if ! ubuntu-image --debug \
    --workdir /rootfs-build/build \
    --output-dir /rootfs-build/build/img \
    classic /rootfs-build/definitions/ubuntu-rootfs-plucky.yaml; then
  echo -e "\n❌ ubuntu-image失败，打印日志（若存在）："
  [ -f "/rootfs-build/build/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap日志不存在"
  [ -f "/rootfs-build/build/img/build.log" ] && cat $_ || echo "ubuntu-image日志不存在"
  # 检查进程存在再kill（解决No such process警告）
  if ps -p $MONITOR_PID > /dev/null; then
      kill $MONITOR_PID || true
  fi
  pkill inotifywait || true
  exit 1
fi

# 检查进程存在再等待（避免警告）
if ps -p $MONITOR_PID > /dev/null; then
    wait $MONITOR_PID || true
fi

# 打包rootfs
tar -cJf /rootfs-build/build/final/ubuntu-25.04-preinstalled-server.tar.xz \
    -p -C /rootfs-build/build/chroot . \
    --sort=name \
    --xattrs

ls -lh /rootfs-build/build/final/ubuntu-25.04-preinstalled-server.tar.xz
SCRIPT_EOF

# 执行Docker Run
docker run --rm -i \
    --privileged \
    --cap-add=ALL \
    -v "${HOST_ROOTFS_ROOT}:/rootfs-build" \
    -v "${BUILD_DIR}:/rootfs-build/build" \
    -v "${CONTAINER_SCRIPT}:/tmp/run-script.sh:ro" \
    "${DOCKER_IMAGE}" \
    /bin/bash /tmp/run-script.sh

rm -f "${CONTAINER_SCRIPT}"

# ===================== 最终验证 =====================
set +x
if [ -f "${FINAL_TAR_PATH}" ]; then
    echo -e "\n🎉 构建成功！"
    echo "产物路径：${FINAL_TAR_PATH}"
    echo "产物大小：$(du -sh "${FINAL_TAR_PATH}" | awk '{print $1}')"
else
    echo -e "\n❌ 构建失败：未生成产物文件" >&2
    exit 1
fi
