#!/bin/bash

create_vpc() {
    local vpc_name=${1:-$VPC_NAME}
    local cidr=${2:-$CIDR_BLOCK}
    
    if [ -z "$vpc_name" ] || [ -z "$cidr" ]; then
        log "ERROR" "Usage: vpcctl create vpc <name> <cidr>"
        log "ERROR" "Or set environment variables: VPC_NAME, CIDR_BLOCK"
        exit 1
    fi
    
    if vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name already exists"
        exit 1
    fi
    
    log "INFO" "Creating VPC: $vpc_name with CIDR $cidr"
    
    local bridge="br-${vpc_name}"
    local gateway_ip=$(get_first_ip "$cidr")
    local prefix=${cidr#*/}
    
    log "INFO" "Creating bridge: $bridge"
    ip link add "$bridge" type bridge
    ip link set "$bridge" up
    
    log "INFO" "Assigning gateway IP: $gateway_ip/$prefix"
    ip addr add "${gateway_ip}/${prefix}" dev "$bridge"

    local config=$(load_config)
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"] = {
        \"cidr\": \"$cidr\",
        \"bridge\": \"$bridge\",
        \"gateway_ip\": \"$gateway_ip\",
        \"subnets\": {},
        \"peerings\": []
    }")
    save_config "$config"
    
    log "INFO" "VPC $vpc_name created successfully"
}

delete_vpc() {
    local vpc_name=${1:-$VPC_NAME}
    
    if [ -z "$vpc_name" ]; then
        log "ERROR" "Usage: vpcctl rm vpc <name>"
        log "ERROR" "Or set environment variable: VPC_NAME"
        exit 1
    fi
    
    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    log "INFO" "Deleting VPC: $vpc_name"
    
    local bridge=$(get_vpc_bridge "$vpc_name")
    
    local subnets=$(jq -r ".vpcs[\"$vpc_name\"].subnets | keys[]" "$CONFIG_FILE")
    for subnet in $subnets; do
        log "INFO" "Deleting subnet: $subnet"
        delete_subnet "$vpc_name" "$subnet"
    done
    
    log "INFO" "Deleting bridge: $bridge"
    ip link set "$bridge" down >>"$LOG_FILE" 2>&1 || true
    ip link delete "$bridge" >>"$LOG_FILE" 2>&1 || true
    
    local config=$(load_config)
    config=$(echo "$config" | jq "del(.vpcs[\"$vpc_name\"])")
    save_config "$config"
    
    log "INFO" "VPC $vpc_name deleted successfully"
}

list_vpcs() {
    local vpcs=$(jq -r '.vpcs | keys[]' "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$vpcs" ]; then
        log "INFO" "No VPCs found"
        return
    fi
    
    echo "VPCs:"
    for vpc in $vpcs; do
        local cidr=$(jq -r ".vpcs[\"$vpc\"].cidr" "$CONFIG_FILE")
        local bridge=$(jq -r ".vpcs[\"$vpc\"].bridge" "$CONFIG_FILE")
        local subnet_count=$(jq -r ".vpcs[\"$vpc\"].subnets | length" "$CONFIG_FILE")
        echo "  $vpc"
        echo "    CIDR: $cidr"
        echo "    Bridge: $bridge"
        echo "    Subnets: $subnet_count"
    done
}
