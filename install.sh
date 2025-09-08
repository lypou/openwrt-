#!/bin/bash
delay_echo() {
    echo "$*"
    awk 'BEGIN { for(i=0; i<300000; i++) { dummy = sqrt(i) } }' /dev/null
}
get_disk_size() {
    local disk="$1"
    fdisk -l "$disk" 2>/dev/null | awk -v d="$disk" '$0 ~ d && / sectors/ { print $5 }'
}
actual_hash(){
    local hash_local="$1"
    local hash_remote="$2"
    local file_local="$3"
    if [ -z  "$hash_local" ]; then
        delay_echo "无法计算文件哈希值，开始清理本地文件并退出运行..."
        rm -f "$file_local"
        exit 1
    fi
    if [ -z  "$hash_remote" ]; then
        delay_echo "远程hash值无效，开始清理本地文件并退出运行..."
        rm -f "$file_local"
        exit 1
    fi
    delay_echo "本地哈希: $hash_local"
    delay_echo "远程哈希: $hash_remote"

if [ "${hash_local,,}" = "${hash_remote,,}" ]; then
    delay_echo "✅ 文件校验无误"    
else
    delay_echo "❌ 哈希不匹配！镜像可能损坏或被篡改"
    delay_echo "💥 正在清除所有相关文件并退出运行..."
    rm -f "$file_local"
    exit 1
fi
}

read -p "本脚本会为您的X86设备安装全新的openwrt镜像，不保留旧的数据，继续吗？(y/N) 默认N: " -n 1 -r
echo
if [[ -z "$REPLY" || ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "操作已取消。"
    exit 0
fi
#1.检查cpu架构
delay_echo "正在检查硬件情况..."
ARCH=$(uname -m)
case "$ARCH" in
    i386|i686|x86_64|amd64)
        delay_echo "✅ 架构检查通过: $ARCH"
        ;;
    *)
        delay_echo "❌ 错误：本脚本仅支持 x86/x86_64 设备，当前架构: $ARCH"
        exit 1
        ;;
esac
#2.检查磁盘大小
DISK_SIZE_BYTES=$(get_disk_size /dev/sda)
if [ -z "$DISK_SIZE_BYTES" ]; then
    delay_echo "❌ 错误：无法获取磁盘大小"
    exit 1
fi
    #2.1 转换为 GB（整数比较）
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
MIN_DISK_GB=2
if [ $DISK_SIZE_GB -lt $MIN_DISK_GB ]; then
    delay_echo "❌ 错误：磁盘空间不足！"
    delay_echo "   当前磁盘: ${DISK_SIZE_GB}GB"
    delay_echo "   要求: >= ${MIN_DISK_GB}GB"
    exit 1
else
    delay_echo "✅ 磁盘空间检查通过: ${DISK_SIZE_GB}GB"
fi
# 3. 检查剩余运行内存（单位：MB）
FREE_MEM_MB=$(free | awk '/^Mem:/ {print int($4 / 1024)}')
MIN_MEM_MB=1536  # 1.5GB = 1536MB
if [ $FREE_MEM_MB -lt $MIN_MEM_MB ]; then
    delay_echo "❌ 错误：剩余内存不足！"
    delay_echo "   当前可用内存: ${FREE_MEM_MB}MB"
    delay_echo "   要求: >= ${MIN_MEM_MB}MB"
    exit 1
else
    delay_echo "✅ 内存检查通过: 可用 ${FREE_MEM_MB}MB"
fi
#4.检查root权限
delay_echo "正在检查权限情况..."
if [ "$EUID" -ne 0 ]; then
    delay_echo "请以 root 权限运行此脚本（如：sudo $0）"
    exit 1    
else
    delay_echo  "    当前用户拥有root权限"
fi
# 5. 检查系统是否自带 wget，没有则安装
delay_echo "正在检查组件情况...."
if ! command -v wget &> /dev/null; then
    delay_echo "wget 未安装，正在尝试安装..."
    if command -v opkg &> /dev/null; then
        opkg update && opkg install -y wget
    elif command -v apt &> /dev/null; then
        apt update && apt install -y wget
    elif command -v yum &> /dev/null; then
        yum install -y wget
    elif command -v dnf &> /dev/null; then
        dnf install -y wget
    else
        delay_echo "    无法识别包管理器，不支持自动安装 wget。"
        exit 1
    fi
else
    delay_echo "    wget 已安装。"
fi
# 6. 检查系统是否自带 jq，没有则安装
if ! command -v jq &> /dev/null; then
    delay_echo "jq 未安装，正在尝试安装..."
    if command -v opkg &> /dev/null; then
        opkg update && opkg install -y jq
    elif command -v apt &> /dev/null; then
        apt update && apt install -y jq
    elif command -v yum &> /dev/null; then
        yum install -y jq
    elif command -v dnf &> /dev/null; then
        dnf install -y jq
    else
        delay_echo "    无法识别包管理器，不支持自动安装 jq。"
        exit 1
    fi
else
    delay_echo "    jq 已安装。"
fi
#7.检查tmp文件夹
delay_echo "正在检查目录情况..."
if [ ! -d "/tmp" ]; then
    delay_echo "    目录不存在，正在创建..."
    mkdir -m 1777 /tmp
    if [ $? -eq 0 ]; then
        delay_echo "        :目录已成功创建。"
    else
        delay_echo "        错误：无法创建临时目录，请检查权限。"
        exit 1
    fi
else
    delay_echo "    目录已存在，无需重复创建"
fi
#8.获取远程信息
delay_echo "正在获取远程版本信息..."
JSON_RESPONSE=$(wget -qO- https://raw.githubusercontent.com/lypou/openwrt-/refs/heads/main/info.json)

if [ -z "$JSON_RESPONSE" ]; then
    delay_echo "错误：无法远程获取数据，请检查网络环境。"
    exit 1
fi
  #8.1 获取并解析版本、地址等信息
json_version=$(echo "$JSON_RESPONSE" | jq -r '.version'| xargs)
json_url=$(echo "$JSON_RESPONSE" | jq -r '.url'| xargs)
json_hash_gz=$(echo "$JSON_RESPONSE" | jq -r '.hash1'| xargs)
json_hash_img=$(echo "$JSON_RESPONSE" | jq -r '.hash2'| xargs)
json_lanip=$(echo "$JSON_RESPONSE" | jq -r '.lanip'| xargs)
json_psw=$(echo "$JSON_RESPONSE" | jq -r '.psw'| xargs)
delay_echo "远程版本:$json_version"
# 定义变量
DOWNLOAD_DIR="/tmp"
GZ_FILE=$(basename "$json_url")
TMP_FILE="$DOWNLOAD_DIR/${GZ_FILE}.$$"
delay_echo "正在下载文件："
delay_echo "保存路径：$DOWNLOAD_DIR/$GZ_FILE"
delay_echo "下载进度："

if wget \
    --timeout=30 \
    --tries=3 \
    --retry-connrefused \
    --no-check-certificate \
    --show-progress \
    -O "$TMP_FILE" \
    "$json_url"; then
    mv "$TMP_FILE" "$DOWNLOAD_DIR/$GZ_FILE"
    delay_echo -e "\n✅ 下载成功,即将校验文件完整性"
else
    rm -f "$TMP_FILE"
    delay_echo -e "\n❌ 下载失败：无法从 '$json_url' 获取文件,请检查网络环境。" >&2
    exit 1
fi
ACTUAL_HASH=$(sha256sum "$DOWNLOAD_DIR/$GZ_FILE" | awk '{print $1}')
actual_hash "$ACTUAL_HASH" "$json_hash_gz" "$DOWNLOAD_DIR/$GZ_FILE"
delay_echo "正在解压 $GZ_FILE ..."
gunzip -c "$DOWNLOAD_DIR/$GZ_FILE" > "$DOWNLOAD_DIR/tmp.img"
if [ $? -ne 0 ]; then
    delay_echo "解压失败，即将清理临时文件，释放空间。"
    rm -f "$DOWNLOAD_DIR/$GZ_FILE" "$DOWNLOAD_DIR/tmp.img"
    exit 1
fi
delay_echo " 解压完成，正在校验镜像完整性..."
ACTUAL_HASH=$(sha256sum "$DOWNLOAD_DIR/tmp.img" | awk '{print $1}')
actual_hash "$ACTUAL_HASH" "$json_hash_img" "$DOWNLOAD_DIR/tmp.img"
echo "警告：即将安装镜像至硬盘，这将完全清除所有数据！"
read -p "确定要继续吗？此操作不可逆！(y/N): " -n 1 -r
echo
if [[ -z "$REPLY" || ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "操作已取消。"
    exit 0
fi


echo "正在使用写入镜像到硬盘，这可能会占用几分钟时间......"
if  dd if="$DOWNLOAD_DIR/tmp.img" of=/dev/sda  ; then
    delay_echo "恭喜：系统镜像已成功写入。"
    echo "后台地址：$json_lanip"
    echo "后台密码: $json_psw"
    echo "交流群：https://t.me/+7hOyc9OQ9cUzMjU1"
else
    echo "错误：镜像写入失败，即将退出。"
    exit 1
fi
# 10. 提示是否重启
read -p "安装完成，是否现在重启系统？(y/N): " -n 1 -r
echo
if [[ -z "$REPLY" || ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "操作已取消。"
    exit 0
fi
else
    delay_echo "安装完成，系统未重启。你可以手动重启以应用更改。"
fi
