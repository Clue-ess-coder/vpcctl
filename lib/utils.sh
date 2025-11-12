#!/bin/bash

CONFIG_FILE="$VPCCTL_HOME/config.json"
LOG_DIR="$VPCCTL_HOME/logs"
LOG_FILE="$LOG_DIR/vpcctl.log"

mkdir -p "$LOG_DIR"

log() {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" >&2
}

check_dependencies() {
    local deps=("ip" "iptables" "jq" "brctl")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "Required command not found: $cmd"
            exit 1
        fi
    done
}

load_config() {
    cat "$CONFIG_FILE"
}

save_config() {
    echo " $1"> "$CONFIG_FILE"
}

vpc_exists() {
    local vpc_name=$1
    jq -e ".vpcs[\"$vpc_name\"]" "$CONFIG_FILE" > /dev/null 2>&1
}

subnet_exists() {
    local vpc_name=$1
    local subnet_name=$2
    jq -e ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"]" "$CONFIG_FILE" > /dev/null 2>&1
}

get_vpc_bridge() {
    local vpc_name=$1
    jq -r ".vpcs[\"$vpc_name\"].bridge" "$CONFIG_FILE"
}

get_vpc_gateway() {
    local vpc_name=$1
    jq -r ".vpcs[\"$vpc_name\"].gateway_ip" "$CONFIG_FILE"
}

get_first_ip() {
    local cidr=$1
    local ip=${cidr%/*}
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    echo "$i1.$i2.$i3.1"
}

get_network() {
    local cidr=$1
    echo "${cidr%/*}"
}

get_next_ip() {
    local vpc_name=$1
    local subnet_name=$2
    jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].next_ip" "$CONFIG_FILE"
}

increment_ip() {
    local ip=$1
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    i4=$((i4 + 1))
    if [ $i4 -gt 254 ]; then
        log "ERROR" "IP address exhausted in subnet"
        return 1
    fi
    echo "$i1.$i2.$i3.$i4"
}

ip_in_cidr() {
    local ip=$1
    local cidr=$2
    
    local network=$(get_network "$cidr")
    local prefix=${cidr#*/}
    
    local ip_int=$(ip_to_int "$ip")
    local net_int=$(ip_to_int "$network")
    
    local mask=$((0xFFFFFFFF << (32 - prefix)))
    
    # Check if IP is in network
    [ $((ip_int & mask)) -eq $((net_int & mask)) ]
}

ip_to_int() {
    local ip=$1
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    echo $((i1 * 256 * 256 * 256 + i2 * 256 * 256 + i3 * 256 + i4))
}

is_ip_allocated() {
    local vpc_name=$1
    local subnet_name=$2
    local ip=$3
    
    jq -e ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips[\"$ip\"]" "$CONFIG_FILE" > /dev/null 2>&1
}

get_next_ip_safe() {
    local vpc_name=$1
    local subnet_name=$2
    
    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name does not exist in VPC $vpc_name"
        return 1
    fi
    
    local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
    local next_ip=$(get_next_ip "$vpc_name" "$subnet_name")
    
    if ! ip_in_cidr "$next_ip" "$cidr"; then
        log "ERROR" "Next IP $next_ip is not within subnet CIDR $cidr"
        return 1
    fi
    
    if is_ip_allocated "$vpc_name" "$subnet_name" "$next_ip"; then
        log "WARN" "IP $next_ip is already allocated, finding next available IP"
        local network=$(get_network "$cidr")
        IFS='.' read -r i1 i2 i3 i4 <<< "$next_ip"  # Start from current next_ip, not network
        local prefix=${cidr#*/}
        local network_ip=$(get_network "$cidr")
        IFS='.' read -r n1 n2 n3 n4 <<< "$network_ip"
        local max_ip=$((n4 + (1 << (32 - prefix)) - 1))
        
        local test_ip="$next_ip"
        while [ $i4 -lt $max_ip ] && [ $i4 -lt 254 ]; do
            if ! is_ip_allocated "$vpc_name" "$subnet_name" "$test_ip"; then
                if ip_in_cidr "$test_ip" "$cidr"; then
                    next_ip="$test_ip"
                    break
                fi
            fi
            i4=$((i4 + 1))
            test_ip="$i1.$i2.$i3.$i4"
        done
        
        if [ $i4 -ge 254 ]; then
            log "ERROR" "IP address pool exhausted in subnet $subnet_name"
            return 1
        fi
    fi
    
    local prefix=${cidr#*/}
    local total_ips=$((1 << (32 - prefix)))
    local allocated_count=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips | length" "$CONFIG_FILE")
    local available=$((total_ips - allocated_count - 10)) # Reserve 10 IPs
    
    if [ $available -lt 5 ]; then
        log "WARN" "Subnet $subnet_name is running low on available IPs ($available remaining)"
    fi
    
    echo "$next_ip"
}

get_available_ip_count() {
    local vpc_name=$1
    local subnet_name=$2
    
    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        echo "0"
        return
    fi
    
    local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
    local prefix=${cidr#*/}
    local total_ips=$((1 << (32 - prefix)))
    local allocated_count=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips | length" "$CONFIG_FILE")
    
    echo $((total_ips - allocated_count - 10)) # Reserve gateway + 9 more
}

get_internet_interface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

get_config_value() {
    local path=$1
    local default=$2
    local value=$(jq -r "$path // \"$default\"" "$CONFIG_FILE" 2>/dev/null)
    echo "${value:-$default}"
}

set_config_value() {
    local path=$1
    local value=$2
    local config=$(load_config)
    config=$(echo "$config" | jq "$path = $value")
    save_config "$config"
}

init_config_defaults() {
    local config=$(load_config)
    
    if ! echo "$config" | jq -e '.settings' > /dev/null 2>&1; then
        config=$(echo "$config" | jq '.settings = {
            "ip_allocation": {
                "start_offset": 10,
                "reserved_ips": ["0", "1", "2", "255"]
            },
            "limits": {
                "max_vpcs": 50,
                "max_subnets_per_vpc": 100
            }
        }')
        save_config "$config"
        log "INFO" "Initialized default configuration settings"
    fi
}

show_usage() {
    cat << EOF
Usage:
  vpcctl create vpc <name> <cidr>
  vpcctl create subnet <vpc> <subnet-name> <cidr> <type>
  vpcctl create peering <vpc1> <vpc2>
  
  vpcctl rm vpc <name>
  vpcctl rm subnet <vpc> <subnet-name>
  vpcctl rm peering <vpc1> <vpc2>
  
  vpcctl ls [vpcs|subnets <vpc>]
  
  vpcctl deploy <vpc> <subnet> <port>
  
  vpcctl firewall <vpc> <subnet> <policy-file>
  vpcctl firewall vpc <vpc> <policy-file>
  vpcctl firewall show <vpc> <subnet>
  vpcctl firewall remove <vpc> <subnet>
  vpcctl firewall vpc remove <vpc>
  
  vpcctl config get <key>
  vpcctl config set <key> <value>
  vpcctl config show

  vpcctl show-logs

Examples:
  vpcctl create vpc my-vpc 10.0.0.0/16
  vpcctl create subnet my-vpc public 10.0.1.0/24 public
  vpcctl create subnet my-vpc private 10.0.2.0/24 private
  vpcctl ls vpcs
  vpcctl deploy my-vpc public 8080
  vpcctl deploy my-vpc public 8080 --ip 10.0.1.50
  vpcctl rm vpc my-vpc
  
  vpcctl firewall my-vpc public allow-http.json
  vpcctl firewall vpc my-vpc vpc-policy.json
  vpcctl firewall show my-vpc public
  vpcctl firewall remove my-vpc public
  
  vpcctl config get '.settings.ip_allocation.start_offset'
  vpcctl config set '.settings.ip_allocation.start_offset' 20
  vpcctl config show

  vpcctl show-logs

Types:
  public  - Subnet with NAT (internet access)
  private - Subnet without internet access
EOF
}
