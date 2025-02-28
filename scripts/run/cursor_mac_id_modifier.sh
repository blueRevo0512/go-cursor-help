#!/bin/bash

# 设置错误处理
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 获取当前用户
get_current_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "无法获取用户名"
    exit 1
fi

# 定义配置文件路径
STORAGE_FILE="$HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
BACKUP_DIR="$HOME/Library/Application Support/Cursor/User/globalStorage/backups"

# 定义 Cursor 应用程序路径
CURSOR_APP_PATH="/Applications/Cursor.app"

# 检查权限
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本"
        echo "示例: sudo $0"
        exit 1
    fi
}

# 检查并关闭 Cursor 进程
check_and_kill_cursor() {
    log_info "检查 Cursor 进程..."
    
    local attempt=1
    local max_attempts=5
    
    # 函数：获取进程详细信息
    get_process_details() {
        local process_name="$1"
        log_debug "正在获取 $process_name 进程详细信息："
        ps aux | grep -i "$process_name" | grep -v grep
    }
    
    while [ $attempt -le $max_attempts ]; do
        CURSOR_PIDS=$(pgrep -i "cursor" || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            log_info "未发现运行中的 Cursor 进程"
            return 0
        fi
        
        log_warn "发现 Cursor 进程正在运行"
        get_process_details "cursor"
        
        log_warn "尝试关闭 Cursor 进程..."
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "尝试强制终止进程..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        if ! pgrep -i "cursor" > /dev/null; then
            log_info "Cursor 进程已成功关闭"
            return 0
        fi
        
        log_warn "等待进程关闭，尝试 $attempt/$max_attempts..."
        ((attempt++))
    done
    
    log_error "在 $max_attempts 次尝试后仍无法关闭 Cursor 进程"
    get_process_details "cursor"
    log_error "请手动关闭进程后重试"
    exit 1
}

# 备份系统 ID
backup_system_id() {
    log_info "正在备份系统 ID..."
    local system_id_file="$BACKUP_DIR/system_id.backup_$(date +%Y%m%d_%H%M%S)"
    
    # 获取并备份 IOPlatformExpertDevice 信息
    {
        echo "# Original System ID Backup" > "$system_id_file"
        echo "## IOPlatformExpertDevice Info:" >> "$system_id_file"
        ioreg -rd1 -c IOPlatformExpertDevice >> "$system_id_file"
        
        chmod 444 "$system_id_file"
        chown "$CURRENT_USER" "$system_id_file"
        log_info "系统 ID 已备份到: $system_id_file"
    } || {
        log_error "备份系统 ID 失败"
        return 1
    }
}

# 备份配置文件
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "配置文件不存在，跳过备份"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    
    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        chown "$CURRENT_USER" "$backup_file"
        log_info "配置已备份到: $backup_file"
    else
        log_error "备份失败"
        exit 1
    fi
}

# 生成随机 ID
generate_random_id() {
    # 生成32字节(64个十六进制字符)的随机数
    openssl rand -hex 32
}

# 生成随机 UUID
generate_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# 修改现有文件
modify_or_add_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if [ ! -f "$file" ]; then
        log_error "文件不存在: $file"
        return 1
    fi
    
    # 确保文件可写
    chmod 644 "$file" || {
        log_error "无法修改文件权限: $file"
        return 1
    }
    
    # 创建临时文件
    local temp_file=$(mktemp)
    
    # 检查key是否存在
    if grep -q "\"$key\":" "$file"; then
        # key存在,执行替换
        sed "s/\"$key\":[[:space:]]*\"[^\"]*\"/\"$key\": \"$value\"/" "$file" > "$temp_file" || {
            log_error "修改配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    else
        # key不存在,添加新的key-value对
        sed "s/}$/,\n    \"$key\": \"$value\"\n}/" "$file" > "$temp_file" || {
            log_error "添加配置失败: $key"
            rm -f "$temp_file"
            return 1
        }
    fi
    
    # 检查临时文件是否为空
    if [ ! -s "$temp_file" ]; then
        log_error "生成的临时文件为空"
        rm -f "$temp_file"
        return 1
    fi
    
    # 使用 cat 替换原文件内容
    cat "$temp_file" > "$file" || {
        log_error "无法写入文件: $file"
        rm -f "$temp_file"
        return 1
    }
    
    rm -f "$temp_file"
    
    # 恢复文件权限
    chmod 444 "$file"
    
    return 0
}

# 生成新的配置
generate_new_config() {
  
    # 修改系统 ID
    log_info "正在修改系统 ID..."
    
    # 备份当前系统 ID
    backup_system_id
    
    # 生成新的系统 UUID
    local new_system_uuid=$(uuidgen)
    
    # 修改系统 UUID
    sudo nvram SystemUUID="$new_system_uuid"
    printf "${YELLOW}系统 UUID 已更新为: $new_system_uuid${NC}\n"
    printf "${YELLOW}请重启系统以使更改生效${NC}\n"
    
    # 将 auth0|user_ 转换为字节数组的十六进制
    local prefix_hex=$(echo -n "auth0|user_" | xxd -p)
    local random_part=$(generate_random_id)
    local machine_id="${prefix_hex}${random_part}"
    
    local mac_machine_id=$(generate_random_id)
    local device_id=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    local sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    
    log_info "正在修改配置文件..."
    # 检查配置文件是否存在
    if [ ! -f "$STORAGE_FILE" ]; then
        log_error "未找到配置文件: $STORAGE_FILE"
        log_warn "请先安装并运行一次 Cursor 后再使用此脚本"
        exit 1
    fi
    
    # 确保配置文件目录存在
    mkdir -p "$(dirname "$STORAGE_FILE")" || {
        log_error "无法创建配置目录"
        exit 1
    }
    
    # 如果文件不存在，创建一个基本的 JSON 结构
    if [ ! -s "$STORAGE_FILE" ]; then
        echo '{}' > "$STORAGE_FILE" || {
            log_error "无法初始化配置文件"
            exit 1
        }
    fi
    
    # 修改现有文件
    modify_or_add_config "telemetry.machineId" "$machine_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.macMachineId" "$mac_machine_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.devDeviceId" "$device_id" "$STORAGE_FILE" || exit 1
    modify_or_add_config "telemetry.sqmId" "$sqm_id" "$STORAGE_FILE" || exit 1
    
    # 设置文件权限和所有者
    chmod 444 "$STORAGE_FILE"  # 改为只读权限
    chown "$CURRENT_USER" "$STORAGE_FILE"
    
    # 验证权限设置
    if [ -w "$STORAGE_FILE" ]; then
        log_warn "无法设置只读权限，尝试使用其他方法..."
        chattr +i "$STORAGE_FILE" 2>/dev/null || true
    else
        log_info "成功设置文件只读权限"
    fi
    
    echo
    log_info "已更新配置: $STORAGE_FILE"
    log_debug "machineId: $machine_id"
    log_debug "macMachineId: $mac_machine_id"
    log_debug "devDeviceId: $device_id"
    log_debug "sqmId: $sqm_id"
}

# 修改 Cursor 主程序文件（安全模式）
modify_cursor_app_files() {
    log_info "正在安全修改 Cursor 主程序文件..."
    
    # 验证应用是否存在
    if [ ! -d "$CURSOR_APP_PATH" ]; then
        log_error "未找到 Cursor.app，请确认安装路径: $CURSOR_APP_PATH"
        return 1
    fi

    # 定义目标文件
    local target_files=(
        "${CURSOR_APP_PATH}/Contents/Resources/app/out/main.js"
        "${CURSOR_APP_PATH}/Contents/Resources/app/out/vs/code/node/cliProcessMain.js"
    )
    
    # 检查文件是否存在并且是否已修改
    local need_modification=false
    local missing_files=false
    
    for file in "${target_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "文件不存在: ${file/$CURSOR_APP_PATH\//}"
            missing_files=true
            continue
        fi
        
        if ! grep -q "return crypto.randomUUID()" "$file" 2>/dev/null; then
            log_info "文件需要修改: ${file/$CURSOR_APP_PATH\//}"
            need_modification=true
            break
        else
            log_info "文件已修改: ${file/$CURSOR_APP_PATH\//}"
        fi
    done
    
    # 如果所有文件都已修改或不存在，则退出
    if [ "$missing_files" = true ]; then
        log_error "部分目标文件不存在，请确认 Cursor 安装是否完整"
        return 1
    fi
    
    if [ "$need_modification" = false ]; then
        log_info "所有目标文件已经被修改过，无需重复操作"
        return 0
    fi

    # 创建临时工作目录
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local temp_dir="/tmp/cursor_reset_${timestamp}"
    local temp_app="${temp_dir}/Cursor.app"
    local backup_app="/tmp/Cursor.app.backup_${timestamp}"
    
    # 清理可能存在的旧临时目录
    if [ -d "$temp_dir" ]; then
        log_info "清理已存在的临时目录..."
        rm -rf "$temp_dir"
    fi
    
    # 创建新的临时目录
    mkdir -p "$temp_dir" || {
        log_error "无法创建临时目录: $temp_dir"
        return 1
    }

    # 备份原应用
    log_info "备份原应用..."
    cp -R "$CURSOR_APP_PATH" "$backup_app" || {
        log_error "无法创建应用备份"
        rm -rf "$temp_dir"
        return 1
    }

    # 复制应用到临时目录
    log_info "创建临时工作副本..."
    cp -R "$CURSOR_APP_PATH" "$temp_dir" || {
        log_error "无法复制应用到临时目录"
        rm -rf "$temp_dir" "$backup_app"
        return 1
    }

    # 确保临时目录的权限正确
    chown -R "$CURRENT_USER:staff" "$temp_dir"
    chmod -R 755 "$temp_dir"

    # 移除签名（增强兼容性）
    log_info "移除应用签名..."
    codesign --remove-signature "$temp_app" || {
        log_warn "移除应用签名失败"
    }

    # 移除所有相关组件的签名
    local components=(
        "$temp_app/Contents/Frameworks/Cursor Helper.app"
        "$temp_app/Contents/Frameworks/Cursor Helper (GPU).app"
        "$temp_app/Contents/Frameworks/Cursor Helper (Plugin).app"
        "$temp_app/Contents/Frameworks/Cursor Helper (Renderer).app"
    )

    for component in "${components[@]}"; do
        if [ -e "$component" ]; then
            log_info "正在移除签名: $component"
            codesign --remove-signature "$component" || {
                log_warn "移除组件签名失败: $component"
            }
        fi
    done
    
    # 修改目标文件
    local modified_count=0
    local files=(
        "${temp_app}/Contents/Resources/app/out/main.js"
        "${temp_app}/Contents/Resources/app/out/vs/code/node/cliProcessMain.js"
    )
    
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            log_warn "文件不存在: ${file/$temp_dir\//}"
            continue
        fi
        
        log_debug "处理文件: ${file/$temp_dir\//}"
        
        # 创建文件备份
        cp "$file" "${file}.bak" || {
            log_error "无法创建文件备份: ${file/$temp_dir\//}"
            continue
        }

        # 读取文件内容
        local content=$(cat "$file")
        
        # 查找 IOPlatformUUID 的位置
        local uuid_pos=$(printf "%s" "$content" | grep -b -o "IOPlatformUUID" | cut -d: -f1)
        if [ -z "$uuid_pos" ]; then
            log_warn "在 $file 中未找到 IOPlatformUUID"
            continue
        fi

        # 从 UUID 位置向前查找 switch
        local before_uuid=${content:0:$uuid_pos}
        local switch_pos=$(printf "%s" "$before_uuid" | grep -b -o "switch" | tail -n1 | cut -d: -f1)
        if [ -z "$switch_pos" ]; then
            log_warn "在 $file 中未找到 switch 关键字"
            continue
        fi

        # 构建新的文件内容
        if printf "%sreturn crypto.randomUUID();\n%s" "${content:0:$switch_pos}" "${content:$switch_pos}" > "$file"; then
            ((modified_count++))
            log_info "成功修改文件: ${file/$temp_dir\//}"
        else
            log_error "文件写入失败: ${file/$temp_dir\//}"
            mv "${file}.bak" "$file"
        fi
        
        # 清理备份
        rm -f "${file}.bak"
    done
    
    if [ "$modified_count" -eq 0 ]; then
        log_error "未能成功修改任何文件"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 重新签名应用（增加重试机制）
    local max_retry=3
    local retry_count=0
    local sign_success=false
    
    while [ $retry_count -lt $max_retry ]; do
        ((retry_count++))
        log_info "尝试签名 (第 $retry_count 次)..."
        
        # 使用更详细的签名参数
        if codesign --sign - --force --deep --preserve-metadata=entitlements,identifier,flags "$temp_app" 2>&1 | tee /tmp/codesign.log; then
            # 验证签名
            if codesign --verify -vvvv "$temp_app" 2>/dev/null; then
                sign_success=true
                log_info "应用签名验证通过"
                break
            else
                log_warn "签名验证失败，错误日志："
                cat /tmp/codesign.log
            fi
        else
            log_warn "签名失败，错误日志："
            cat /tmp/codesign.log
        fi
        
        sleep 1
    done

    if ! $sign_success; then
        log_error "经过 $max_retry 次尝试仍无法完成签名"
        log_error "请手动执行以下命令完成签名："
        echo -e "${BLUE}sudo codesign --sign - --force --deep '${temp_app}'${NC}"
        echo -e "${YELLOW}操作完成后，请手动将应用复制到原路径：${NC}"
        echo -e "${BLUE}sudo cp -R '${temp_app}' '/Applications/'${NC}"
        log_info "临时文件保留在：${temp_dir}"
        return 1
    fi

    # 替换原应用
    log_info "安装修改版应用..."
    if ! sudo rm -rf "$CURSOR_APP_PATH" || ! sudo cp -R "$temp_app" "/Applications/"; then
        log_error "应用替换失败，正在恢复..."
        sudo rm -rf "$CURSOR_APP_PATH"
        sudo cp -R "$backup_app" "$CURSOR_APP_PATH"
        rm -rf "$temp_dir" "$backup_app"
        return 1
    fi
    
    # 清理临时文件
    rm -rf "$temp_dir" "$backup_app"
    
    # 设置权限
    sudo chown -R "$CURRENT_USER:staff" "$CURSOR_APP_PATH"
    sudo chmod -R 755 "$CURSOR_APP_PATH"
    
    log_info "Cursor 主程序文件修改完成！原版备份在: ${backup_app/$HOME/\~}"
    return 0
}

# 显示文件树结构
show_file_tree() {
    local base_dir=$(dirname "$STORAGE_FILE")
    echo
    log_info "文件结构:"
    echo -e "${BLUE}$base_dir${NC}"
    echo "├── globalStorage"
    echo "│   ├── storage.json (已修改)"
    echo "│   └── backups"
    
    # 列出备份文件
    if [ -d "$BACKUP_DIR" ]; then
        local backup_files=("$BACKUP_DIR"/*)
        if [ ${#backup_files[@]} -gt 0 ]; then
            for file in "${backup_files[@]}"; do
                if [ -f "$file" ]; then
                    echo "│       └── $(basename "$file")"
                fi
            done
        else
            echo "│       └── (空)"
        fi
    fi
    echo
}

# 显示公众号信息
show_follow_info() {
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${YELLOW}  关注公众号【煎饼果子卷AI】一起交流更多Cursor技巧和AI知识(脚本免费、关注公众号加群有更多技巧和大佬) ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo
}

# 禁用自动更新
disable_auto_update() {
    local updater_path="$HOME/Library/Application Support/Caches/cursor-updater"
    local app_update_yml="/Applications/Cursor.app/Contents/Resources/app-update.yml"
    
    echo
    log_info "正在禁用 Cursor 自动更新..."
    
    # 备份并清空 app-update.yml
    if [ -f "$app_update_yml" ]; then
        log_info "备份并修改 app-update.yml..."
        if ! sudo cp "$app_update_yml" "${app_update_yml}.bak" 2>/dev/null; then
            log_warn "备份 app-update.yml 失败，继续执行..."
        fi
        
        if sudo bash -c "echo '' > \"$app_update_yml\"" && \
           sudo chmod 444 "$app_update_yml"; then
            log_info "成功禁用 app-update.yml"
        else
            log_error "修改 app-update.yml 失败，请手动执行以下命令："
            echo -e "${BLUE}sudo cp \"$app_update_yml\" \"${app_update_yml}.bak\"${NC}"
            echo -e "${BLUE}sudo bash -c 'echo \"\" > \"$app_update_yml\"'${NC}"
            echo -e "${BLUE}sudo chmod 444 \"$app_update_yml\"${NC}"
        fi
    else
        log_warn "未找到 app-update.yml 文件"
    fi
    
    # 同时也处理 cursor-updater
    log_info "处理 cursor-updater..."
    if sudo rm -rf "$updater_path" && \
       sudo touch "$updater_path" && \
       sudo chmod 444 "$updater_path"; then
        log_info "成功禁用 cursor-updater"
    else
        log_error "禁用 cursor-updater 失败，请手动执行以下命令："
        echo -e "${BLUE}sudo rm -rf \"$updater_path\" && sudo touch \"$updater_path\" && sudo chmod 444 \"$updater_path\"${NC}"
    fi
    
    echo
    log_info "验证方法："
    echo "1. 运行命令：ls -l \"$updater_path\""
    echo "   确认文件权限显示为：r--r--r--"
    echo "2. 运行命令：ls -l \"$app_update_yml\""
    echo "   确认文件权限显示为：r--r--r--"
    echo
    log_info "完成后请重启 Cursor"
}

# 生成随机MAC地址
generate_random_mac() {
    # 生成随机MAC地址,保持第一个字节的第二位为0(保证是单播地址)
    printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# 获取网络接口列表
get_network_interfaces() {
    networksetup -listallhardwareports | awk '/Hardware Port|Ethernet Address/ {print $NF}' | paste - - | grep -v 'N/A'
}

# 备份MAC地址
backup_mac_addresses() {
    log_info "正在备份MAC地址..."
    local backup_file="$BACKUP_DIR/mac_addresses.backup_$(date +%Y%m%d_%H%M%S)"
    
    {
        echo "# Original MAC Addresses Backup - $(date)" > "$backup_file"
        echo "## Network Interfaces:" >> "$backup_file"
        networksetup -listallhardwareports >> "$backup_file"
        
        chmod 444 "$backup_file"
        chown "$CURRENT_USER" "$backup_file"
        log_info "MAC地址已备份到: $backup_file"
    } || {
        log_error "备份MAC地址失败"
        return 1
    }
}

# 修改MAC地址
modify_mac_address() {
    log_info "正在获取网络接口信息..."
    
    # 备份当前MAC地址
    backup_mac_addresses
    
    # 获取所有网络接口
    local interfaces=$(get_network_interfaces)
    
    if [ -z "$interfaces" ]; then
        log_error "未找到可用的网络接口"
        return 1
    fi
    
    echo
    log_info "发现以下网络接口:"
    echo "$interfaces" | nl -w2 -s') '
    echo
    
    echo -n "请选择要修改的接口编号 (按回车跳过): "
    read -r choice
    
    if [ -z "$choice" ]; then
        log_info "跳过MAC地址修改"
        return 0
    fi
    
    # 获取选择的接口名称
    local selected_interface=$(echo "$interfaces" | sed -n "${choice}p" | awk '{print $1}')
    
    if [ -z "$selected_interface" ]; then
        log_error "无效的选择"
        return 1
    fi
    
    # 生成新的MAC地址
    local new_mac=$(generate_random_mac)
    
    log_info "正在修改接口 $selected_interface 的MAC地址..."
    
    # 关闭网络接口
    sudo ifconfig "$selected_interface" down || {
        log_error "无法关闭网络接口"
        return 1
    }
    
    # 修改MAC地址
    if sudo ifconfig "$selected_interface" ether "$new_mac"; then
        # 重新启用网络接口
        sudo ifconfig "$selected_interface" up
        log_info "成功修改MAC地址为: $new_mac"
        echo
        log_warn "请注意: MAC地址修改可能需要重新连接网络才能生效"
    else
        log_error "修改MAC地址失败"
        # 尝试恢复网络接口
        sudo ifconfig "$selected_interface" up
        return 1
    fi
}

# 新增恢复功能选项
restore_feature() {
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "备份目录不存在"
        return 1
    fi

    # 使用 find 命令获取备份文件列表并存储到数组
    backup_files=()
    while IFS= read -r file; do
        [ -f "$file" ] && backup_files+=("$file")
    done < <(find "$BACKUP_DIR" -name "*.backup_*" -type f 2>/dev/null | sort)
    
    # 检查是否找到备份文件
    if [ ${#backup_files[@]} -eq 0 ]; then
        log_warn "未找到任何备份文件"
        return 1
    fi
    
    echo
    log_info "可用的备份文件："
    echo "0) 退出 (默认)"
    
    # 显示备份文件列表
    for i in "${!backup_files[@]}"; do
        echo "$((i+1))) $(basename "${backup_files[$i]}")"
    done
    
    echo
    echo -n "请选择要恢复的备份文件编号 [0-${#backup_files[@]}] (默认: 0): "
    read -r choice
    
    # 处理用户输入
    if [ -z "$choice" ] || [ "$choice" = "0" ]; then
        log_info "跳过恢复操作"
        return 0
    fi
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt "${#backup_files[@]}" ]; then
        log_error "无效的选择"
        return 1
    fi
    
    # 获取选择的备份文件
    local selected_backup="${backup_files[$((choice-1))]}"
    
    # 验证文件存在性和可读性
    if [ ! -f "$selected_backup" ] || [ ! -r "$selected_backup" ]; then
        log_error "无法访问选择的备份文件"
        return 1
    fi
    
    # 尝试恢复配置
    if cp "$selected_backup" "$STORAGE_FILE"; then
        chmod 644 "$STORAGE_FILE"
        chown "$CURRENT_USER" "$STORAGE_FILE"
        log_info "已从备份文件恢复配置: $(basename "$selected_backup")"
        return 0
    else
        log_error "恢复配置失败"
        return 1
    fi
}

# 主函数
main() {
    
    # 新增环境检查
    if [[ $(uname) != "Darwin" ]]; then
        log_error "本脚本仅支持 macOS 系统"
        exit 1
    fi
    
    
    clear
    # 显示 Logo
    echo -e "
    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
    "
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}   Cursor 设备ID 修改工具          ${NC}"
    echo -e "${YELLOW}  关注公众号【煎饼果子卷AI】     ${NC}"
    echo -e "${YELLOW}  一起交流更多Cursor技巧和AI知识(脚本免费、关注公众号加群有更多技巧和大佬)  ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    echo -e "${YELLOW}[重要提示]${NC} 本工具支持 Cursor v0.45.x"
    echo -e "${YELLOW}[重要提示]${NC} 本工具免费，如果对您有帮助，请关注公众号【煎饼果子卷AI】"
    echo
    
    check_permissions
    check_and_kill_cursor
    backup_config
    generate_new_config
    modify_cursor_app_files
    
    # 添加MAC地址修改选项
    echo
    log_warn "是否要修改MAC地址？"
    echo "0) 否 - 保持默认设置 (默认)"
    echo "1) 是 - 修改MAC地址"
    echo -n "请输入选择 [0-1] (默认 0): "
    read -r choice
    
    # 处理用户输入（包括空输入和无效输入）
    case "$choice" in
        1)
            if modify_mac_address; then
                log_info "MAC地址修改完成！"
            else
                log_error "MAC地址修改失败"
            fi
            ;;
        *)
            log_info "已跳过MAC地址修改"
            ;;
    esac
    
    show_file_tree
    show_follow_info
  
    # 直接执行禁用自动更新
    disable_auto_update

    log_info "请重启 Cursor 以应用新的配置"

    # 新增恢复功能选项
    #restore_feature

    # 显示最后的提示信息
    show_follow_info

    
}

# 执行主函数
main

