#!/bin/bash

create_subnet() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name_arg="$2"
    local cidr_arg="$3"
    local type_arg="$4"

    local type="$type_arg"
    local cidr="$cidr_arg"
    local subnet_name="$subnet_name_arg"

    if [ "$type" = "public" ]; then

        if [ -z "$subnet_name" ]; then
            subnet_name="${PUBLIC_SUBNET_NAME:-pub}"
        fi

        if [ -z "$cidr" ]; then
            cidr="$PUBLIC_SUBNET"
        fi
    elif [ "$type" = "private" ]; then
        if [ -z "$subnet_name" ]; then
            subnet_name="${PRIVATE_SUBNET_NAME:-priv}"
        fi

        if [ -z "$cidr" ]; then
            cidr="$PRIVATE_SUBNET"
        fi
    fi

    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ] || [ -z "$cidr" ] || [ -z "$type" ]; then
        log "ERROR" "Usage: vpcctl create subnet <vpc> <subnet-name> <cidr> <type>"
        log "ERROR" "Or set environment variables:"
        log "ERROR" "  VPC_NAME - VPC name"
        log "ERROR" "  PUBLIC_SUBNET - Public subnet CIDR (e.g., 10.0.1.0/24)"
        log "ERROR" "  PRIVATE_SUBNET - Private subnet CIDR (e.g., 10.0.2.0/24)"
        log "ERROR" "  PUBLIC_SUBNET_NAME - Optional public subnet name (defaults to pub)"
        log "ERROR" "  PRIVATE_SUBNET_NAME - Optional private subnet name (defaults to priv)"
        log "ERROR" "Then run: vpcctl create subnet \"\" \"\" \"\" public"
        exit 1
    fi

    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    if subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name already exists in VPC $vpc_name"
        exit 1
    fi
    
    if [[ "$type" != "public" && "$type" != "private" ]]; then
        log "ERROR" "Type must be 'public' or 'private'"
        exit 1
    fi
    
    log "INFO" "Creating subnet: $subnet_name in VPC $vpc_name"
    
    local ns="ns-${vpc_name}-${subnet_name}"
    local veth_host="veth-${subnet_name}-h"
    local veth_ns="veth-${subnet_name}-ns"
    local gateway_ip=$(get_first_ip "$cidr")
    local prefix=${cidr#*/}
    local vpc_gateway=$(get_vpc_gateway "$vpc_name")
    local bridge=$(get_vpc_bridge "$vpc_name")
    
    log "INFO" "Creating namespace: $ns"
    ip netns add "$ns"
    
    log "INFO" "Creating veth pair: $veth_host <-> $veth_ns"
    ip link add "$veth_host" type veth peer name "$veth_ns"
    
    log "INFO" "Attaching $veth_host to bridge $bridge"
    ip link set "$veth_host" master "$bridge"
    ip link set "$veth_host" up
    
    log "INFO" "Moving $veth_ns into namespace $ns"
    ip link set "$veth_ns" netns "$ns"
    
    log "INFO" "Configuring interface in namespace"
    ip netns exec "$ns" ip addr add "${gateway_ip}/${prefix}" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up
    ip netns exec "$ns" ip link set lo up

    local vpc_cidr=$(jq -r ".vpcs[\"$vpc_name\"].cidr" "$CONFIG_FILE")
    log "INFO" "Adding route to VPC CIDR $vpc_cidr"
    ip netns exec "$ns" ip route add "$vpc_cidr" dev "$veth_ns"
    
    log "INFO" "Adding default route"
    ip netns exec "$ns" ip route add default via "$vpc_gateway" dev "$veth_ns"
    
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    local bridge=$(get_vpc_bridge "$vpc_name")
    iptables -C FORWARD -i "$bridge" -o "$bridge" -j ACCEPT >>"$LOG_FILE" 2>&1 || \
        iptables -I FORWARD 1 -i "$bridge" -o "$bridge" -j ACCEPT >>"$LOG_FILE" 2>&1
    
    local nat_enabled=false
    if [ "$type" = "public" ]; then
        log "INFO" "Enabling NAT for public subnet"
        enable_nat "$cidr"
        nat_enabled=true
    fi
    
    if [ "$type" = "public" ]; then
        log "INFO" "Adding route from host to public subnet $cidr"
        ip route add "$cidr" dev "$bridge" >>"$LOG_FILE" 2>&1 || true
    fi
    
    if [ "$type" = "private" ]; then
        log "INFO" "Blocking host access to private subnet $cidr"
        iptables -C OUTPUT -d "$cidr" -j DROP >>"$LOG_FILE" 2>&1 || \
            iptables -I OUTPUT 1 -d "$cidr" -j DROP >>"$LOG_FILE" 2>&1
        log "INFO" "Host access to private subnet $cidr is blocked"
    fi
    
    local network=$(get_network "$cidr")
    IFS='.' read -r i1 i2 i3 i4 <<< "$network"
    local next_ip="$i1.$i2.$i3.10"
    
    local config=$(load_config)
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"] = {
        \"cidr\": \"$cidr\",
        \"type\": \"$type\",
        \"namespace\": \"$ns\",
        \"veth_host\": \"$veth_host\",
        \"veth_ns\": \"$veth_ns\",
        \"gateway_ip\": \"$gateway_ip\",
        \"nat_enabled\": $nat_enabled,
        \"next_ip\": \"$next_ip\",
        \"allocated_ips\": {}
    }")
    save_config "$config"
    
    log "INFO" "Subnet $subnet_name created successfully"
}

delete_subnet() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name="$2"

    if [ -z "$subnet_name" ]; then
        subnet_name="${PUBLIC_SUBNET_NAME:-${PRIVATE_SUBNET_NAME:-}}"
    fi

    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl rm subnet <vpc> <subnet-name>"
        log "ERROR" "Or set environment variables:"
        log "ERROR" "  VPC_NAME"
        log "ERROR" "  PUBLIC_SUBNET_NAME or PRIVATE_SUBNET_NAME"
        exit 1
    fi

    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name does not exist in VPC $vpc_name"
        exit 1
    fi
    
    log "INFO" "Deleting subnet: $subnet_name from VPC $vpc_name"
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    local veth_host=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].veth_host" "$CONFIG_FILE")
    local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
    local nat_enabled=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].nat_enabled" "$CONFIG_FILE")
    
    log "INFO" "Stopping all services in subnet $subnet_name"
    jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips | to_entries[] | \"\(.value.pid)|\(.value.nginx_dir)\"" "$CONFIG_FILE" 2>/dev/null | while IFS='|' read -r pid nginx_dir; do
        if [ -n "$pid" ] && [ "$pid" != "null" ]; then
            if kill -0 "$pid" >>"$LOG_FILE" 2>&1; then
                log "INFO" "  Stopping service with PID: $pid"
                kill "$pid" >>"$LOG_FILE" 2>&1 || true
                sleep 1
                if kill -0 "$pid" >>"$LOG_FILE" 2>&1; then
                    log "INFO" "  Force killing process: $pid"
                    kill -9 "$pid" >>"$LOG_FILE" 2>&1 || true
                fi
            fi
        fi
        
        if [ -n "$nginx_dir" ] && [ "$nginx_dir" != "null" ] && [ -d "$nginx_dir" ]; then
            log "INFO" "  Removing nginx directory: $nginx_dir"
            rm -rf "$nginx_dir" >>"$LOG_FILE" 2>&1 || true
        fi
    done
    
    if [ "$nat_enabled" = "true" ]; then
        log "INFO" "Disabling NAT for $cidr"
        disable_nat "$cidr"
    fi
    
    if [ "$nat_enabled" = "true" ]; then
        log "INFO" "Removing route from host to subnet $cidr"
        ip route del "$cidr" dev "$(get_vpc_bridge "$vpc_name")" >>"$LOG_FILE" 2>&1 || true
    fi

    if [ "$nat_enabled" != "true" ]; then
        log "INFO" "Removing iptables block for private subnet $cidr"
        iptables -D OUTPUT -d "$cidr" -j DROP >>"$LOG_FILE" 2>&1 || true
    fi
    
    log "INFO" "Deleting namespace: $ns"
    ip netns delete "$ns" >>"$LOG_FILE" 2>&1 || true
    
    ip link delete "$veth_host" >>"$LOG_FILE" 2>&1 || true
    
    local config=$(load_config)
    config=$(echo "$config" | jq "del(.vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"])")
    save_config "$config"
    
    log "INFO" "Subnet $subnet_name deleted successfully"
}

list_subnets() {
    local vpc_name=$1
    
    if [ -z "$vpc_name" ]; then
        log "ERROR" "Usage: vpcctl ls subnets <vpc>"
        exit 1
    fi
    
    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    local subnets=$(jq -r ".vpcs[\"$vpc_name\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$subnets" ]; then
        log "INFO" "No subnets found in VPC $vpc_name"
        return
    fi
    
    echo "Subnets in VPC $vpc_name:"
    for subnet in $subnets; do
        local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet\"].cidr" "$CONFIG_FILE")
        local type=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet\"].type" "$CONFIG_FILE")
        local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet\"].namespace" "$CONFIG_FILE")
        echo "  $subnet"
        echo "    CIDR: $cidr"
        echo "    Type: $type"
        echo "    Namespace: $ns"
    done
}
