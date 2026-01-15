#!/bin/bash
#================================================================
# 节点批量部署脚本 - 一键自动化
# 用途: 批量安装节点、自动优化、自动对接Xboard后台
# 配置: 编辑 nodes.conf 文件
#================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "
╔═══════════════════════════════════════════════════════════╗
║        Xboard 节点批量部署工具 v2.0                       ║
║        一键安装+优化+对接                                 ║
╚═══════════════════════════════════════════════════════════╝
"

# 配置文件检查
if [ ! -f "nodes.conf" ]; then
    echo -e "${RED}❌ 错误: 未找到 nodes.conf 配置文件${NC}"
    echo ""
    echo "正在创建配置文件模板..."
    cat > nodes.conf <<'EOF'
# ========================================
# 节点配置文件
# 格式: 节点名称|IP地址|SSH端口|SSH密码|节点组ID|协议|端口
# ========================================

# 示例（删除本行后使用）
香港-01|45.76.123.45|22|your_password|1|vless|443
日本-01|139.180.200.11|22|your_password|1|vless|443
美国-01|207.246.100.22|22|your_password|2|vmess|443

# 节点组说明:
# 1 = 高级套餐节点
# 2 = 标准套餐节点
# 0 = 所有套餐可用

# 协议说明:
# vless = 推荐，性能好
# vmess = 兼容性好
# trojan = 抗封锁
EOF
    echo -e "${GREEN}✓ 已创建 nodes.conf 模板${NC}"
    echo ""
    echo "请编辑 nodes.conf 文件，填入你的节点信息后重新运行"
    exit 0
fi

# 读取Xboard配置
if [ ! -f "xboard.conf" ]; then
    echo -e "${YELLOW}⚠ 未找到 xboard.conf，创建配置...${NC}"
    read -p "请输入 Xboard 面板地址 (如 https://panel.example.com): " PANEL_URL
    read -p "请输入 Xboard API Token: " API_TOKEN
    
    cat > xboard.conf <<EOF
PANEL_URL="https://shukevpn.com"
API_TOKEN="a0jabOuWeqdqTLXI7ybNMumd9"
EOF
    echo -e "${GREEN}✓ 配置已保存${NC}"
fi

source xboard.conf

# 安装本地依赖
echo -e "\n${YELLOW}► 检查本地依赖...${NC}"
if ! command -v sshpass &> /dev/null; then
    echo "安装 sshpass..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y sshpass
    elif [ -f /etc/redhat-release ]; then
        yum install -y sshpass
    fi
fi

# 统计信息
TOTAL=0
SUCCESS=0
FAILED=0

# 部署函数
deploy_node() {
    local NAME=$1
    local IP=$2
    local PORT=$3
    local PASSWORD=$4
    local GROUP=$5
    local PROTOCOL=$6
    local LISTEN_PORT=$7
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}► 开始部署: $NAME ($IP)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    TOTAL=$((TOTAL + 1))
    
    # 生成远程安装脚本
    cat > /tmp/install_node_${IP}.sh <<'REMOTE_SCRIPT'
#!/bin/bash
set -e

# 系统检测
if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt-get"
    $PKG_MANAGER update
elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
else
    echo "不支持的系统"
    exit 1
fi

# 安装3x-ui
echo "► 安装 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
admin
admin123
54321
EOF

# 系统优化
echo "► 系统优化..."

# BBR加速
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf <<SYSCTL
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
fs.file-max=1000000
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_mem=134217728 134217728 134217728
SYSCTL
    sysctl -p
fi

# 文件限制
if ! grep -q "* soft nofile 1000000" /etc/security/limits.conf; then
    cat >> /etc/security/limits.conf <<LIMITS
* soft nofile 1000000
* hard nofile 1000000
LIMITS
fi

# 防火墙
if command -v ufw &> /dev/null; then
    ufw allow LISTEN_PORT_PLACEHOLDER/tcp
    ufw allow 54321/tcp
fi

echo "✓ 节点安装完成"
REMOTE_SCRIPT

    # 替换占位符
    sed -i "s/LISTEN_PORT_PLACEHOLDER/$LISTEN_PORT/g" /tmp/install_node_${IP}.sh
    
    # 上传并执行
    if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -p $PORT root@$IP "bash -s" < /tmp/install_node_${IP}.sh; then
        echo -e "${GREEN}✓ 节点安装成功${NC}"
        
        # 对接到Xboard
        echo "► 对接到 Xboard 后台..."
        
        # 获取节点信息
        NODE_ID=$(curl -s -X POST "$PANEL_URL/api/v1/admin/node" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"$NAME\",
                \"group_id\": $GROUP,
                \"host\": \"$IP\",
                \"port\": $LISTEN_PORT,
                \"server_port\": $LISTEN_PORT,
                \"protocol\": \"$PROTOCOL\",
                \"network\": \"ws\",
                \"networkSettings\": {
                    \"path\": \"/xray\",
                    \"headers\": {}
                },
                \"security\": \"tls\",
                \"show\": 1,
                \"sort\": 0
            }" | grep -oP '(?<="id":)\d+')
        
        if [ -n "$NODE_ID" ]; then
            echo -e "${GREEN}✓ 已对接到Xboard (节点ID: $NODE_ID)${NC}"
            SUCCESS=$((SUCCESS + 1))
        else
            echo -e "${YELLOW}⚠ 自动对接失败，请手动添加节点${NC}"
            SUCCESS=$((SUCCESS + 1))
        fi
    else
        echo -e "${RED}✗ 节点安装失败${NC}"
        FAILED=$((FAILED + 1))
    fi
    
    # 清理临时文件
    rm -f /tmp/install_node_${IP}.sh
}

# 读取并部署所有节点
echo -e "\n${YELLOW}► 读取节点配置...${NC}"

while IFS='|' read -r name ip port password group protocol listen_port; do
    # 跳过注释和空行
    [[ "$name" =~ ^#.*$ ]] && continue
    [[ -z "$name" ]] && continue
    
    # 去除空格
    name=$(echo "$name" | xargs)
    ip=$(echo "$ip" | xargs)
    port=$(echo "$port" | xargs)
    password=$(echo "$password" | xargs)
    group=$(echo "$group" | xargs)
    protocol=$(echo "$protocol" | xargs)
    listen_port=$(echo "$listen_port" | xargs)
    
    # 部署节点
    deploy_node "$name" "$ip" "$port" "$password" "$group" "$protocol" "$listen_port"
    
done < nodes.conf

# 统计报告
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ 部署完成${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "总计: $TOTAL 个节点"
echo -e "成功: ${GREEN}$SUCCESS${NC} 个"
echo -e "失败: ${RED}$FAILED${NC} 个"
echo ""
echo "后续操作:"
echo "1. 登录 Xboard 后台查看节点状态"
echo "2. 测试节点连通性"
echo "3. 配置节点套餐关联"
echo ""
