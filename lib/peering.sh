#!/bin/bash

create_peering() {
    local vpc1=$1
    local vpc2=$2
    
    if [ -z "$vpc1" ] || [ -z "$vpc2" ]; then
        log "ERROR" "Usage: vpcctl create peering <vpc1> <vpc2>"
        exit 1
    fi
    
    if ! vpc_exists "$vpc1"; then
        log "ERROR" "VPC $vpc1 does not exist"
        exit 1
    fi
    
    if ! vpc_exists "$vpc2"; then
        log "ERROR" "VPC $vpc2 does not exist"
        exit 1
    fi
    
    if [ "$vpc1" = "$vpc2" ]; then
        log "ERROR" "Cannot peer a VPC with itself"
        exit 1
    fi

    local existing=$(jq -r ".vpcs[\"$vpc1\"].peerings[]? | select(. == \"$vpc2\")" "$CONFIG_FILE")
    if [ -n "$existing" ]; then
        log "ERROR" "Peering between $vpc1 and $vpc2 already exists"
        exit 1
    fi
    
    log "INFO" "Creating peering between $vpc1 and $vpc2"

    local bridge1=$(get_vpc_bridge "$vpc1")
    local bridge2=$(get_vpc_bridge "$vpc2")
    local cidr1=$(jq -r ".vpcs[\"$vpc1\"].cidr" "$CONFIG_FILE")
    local cidr2=$(jq -r ".vpcs[\"$vpc2\"].cidr" "$CONFIG_FILE")

    local veth1="p-${vpc1}-${vpc2}-0"
    local veth2="p-${vpc1}-${vpc2}-1"
    
    log "INFO" "Creating veth pair: $veth1 <-> $veth2"
    ip link add "$veth1" type veth peer name "$veth2"

    log "INFO" "Attaching $veth1 to $bridge1"
    ip link set "$veth1" master "$bridge1"
    ip link set "$veth1" up
    
    log "INFO" "Attaching $veth2 to $bridge2"
    ip link set "$veth2" master "$bridge2"
    ip link set "$veth2" up

    log "INFO" "Adding route: $cidr2 via $bridge1"
    ip route add "$cidr2" dev "$bridge1" >>"$LOG_FILE" 2>&1 || true
    
    log "INFO" "Adding route: $cidr1 via $bridge2"
    ip route add "$cidr1" dev "$bridge2" >>"$LOG_FILE" 2>&1 || true

    log "INFO" "Allowing forwarding between bridges"
    iptables -C FORWARD -i "$bridge1" -o "$bridge2" -j ACCEPT >>"$LOG_FILE" 2>&1 || \
        iptables -I FORWARD 1 -i "$bridge1" -o "$bridge2" -j ACCEPT >>"$LOG_FILE" 2>&1
    iptables -C FORWARD -i "$bridge2" -o "$bridge1" -j ACCEPT >>"$LOG_FILE" 2>&1 || \
        iptables -I FORWARD 1 -i "$bridge2" -o "$bridge1" -j ACCEPT >>"$LOG_FILE" 2>&1

    log "INFO" "Adding routes in VPC1 namespaces to reach VPC2"
    local subnets1=$(jq -r ".vpcs[\"$vpc1\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    for subnet in $subnets1; do
        local ns=$(jq -r ".vpcs[\"$vpc1\"].subnets[\"$subnet\"].namespace" "$CONFIG_FILE")
        local veth_ns=$(jq -r ".vpcs[\"$vpc1\"].subnets[\"$subnet\"].veth_ns" "$CONFIG_FILE")
        if [ -n "$ns" ] && [ "$ns" != "null" ]; then
            log "INFO" "  Adding route in $ns to $cidr2"
            ip netns exec "$ns" ip route add "$cidr2" dev "$veth_ns" >>"$LOG_FILE" 2>&1 || true
        fi
    done

    log "INFO" "Adding routes in VPC2 namespaces to reach VPC1"
    local subnets2=$(jq -r ".vpcs[\"$vpc2\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    for subnet in $subnets2; do
        local ns=$(jq -r ".vpcs[\"$vpc2\"].subnets[\"$subnet\"].namespace" "$CONFIG_FILE")
        local veth_ns=$(jq -r ".vpcs[\"$vpc2\"].subnets[\"$subnet\"].veth_ns" "$CONFIG_FILE")
        if [ -n "$ns" ] && [ "$ns" != "null" ]; then
            log "INFO" "  Adding route in $ns to $cidr1"
            ip netns exec "$ns" ip route add "$cidr1" dev "$veth_ns" >>"$LOG_FILE" 2>&1 || true
        fi
    done

    local config=$(load_config)
    config=$(echo "$config" | jq ".vpcs[\"$vpc1\"].peerings += [\"$vpc2\"]")
    config=$(echo "$config" | jq ".vpcs[\"$vpc2\"].peerings += [\"$vpc1\"]")
    save_config "$config"
    
    log "INFO" "Peering created between $vpc1 and $vpc2"
}

delete_peering() {
    local vpc1=$1
    local vpc2=$2
    
    if [ -z "$vpc1" ] || [ -z "$vpc2" ]; then
        log "ERROR" "Usage: vpcctl rm peering <vpc1> <vpc2>"
        exit 1
    fi
    
    if ! vpc_exists "$vpc1" || ! vpc_exists "$vpc2"; then
        log "ERROR" "One or both VPCs do not exist"
        exit 1
    fi

    local existing=$(jq -r ".vpcs[\"$vpc1\"].peerings[]? | select(. == \"$vpc2\")" "$CONFIG_FILE")
    if [ -z "$existing" ]; then
        log "ERROR" "No peering exists between $vpc1 and $vpc2"
        exit 1
    fi
    
    log "INFO" "Deleting peering between $vpc1 and $vpc2"

    local bridge1=$(get_vpc_bridge "$vpc1")
    local bridge2=$(get_vpc_bridge "$vpc2")
    local cidr1=$(jq -r ".vpcs[\"$vpc1\"].cidr" "$CONFIG_FILE")
    local cidr2=$(jq -r ".vpcs[\"$vpc2\"].cidr" "$CONFIG_FILE")

    log "INFO" "Removing routes from VPC1 namespaces"
    local subnets1=$(jq -r ".vpcs[\"$vpc1\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    for subnet in $subnets1; do
        local ns=$(jq -r ".vpcs[\"$vpc1\"].subnets[\"$subnet\"].namespace" "$CONFIG_FILE")
        if [ -n "$ns" ] && [ "$ns" != "null" ]; then
            ip netns exec "$ns" ip route del "$cidr2" >>"$LOG_FILE" 2>&1 || true
        fi
    done
    
    log "INFO" "Removing routes from VPC2 namespaces"
    local subnets2=$(jq -r ".vpcs[\"$vpc2\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    for subnet in $subnets2; do
        local ns=$(jq -r ".vpcs[\"$vpc2\"].subnets[\"$subnet\"].namespace" "$CONFIG_FILE")
        if [ -n "$ns" ] && [ "$ns" != "null" ]; then
            ip netns exec "$ns" ip route del "$cidr1" >>"$LOG_FILE" 2>&1 || true
        fi
    done

    iptables -D FORWARD -i "$bridge1" -o "$bridge2" -j ACCEPT >>"$LOG_FILE" 2>&1 || true
    iptables -D FORWARD -i "$bridge2" -o "$bridge1" -j ACCEPT >>"$LOG_FILE" 2>&1 || true
    
    local veth1="p-${vpc1}-${vpc2}-0"
    log "INFO" "Deleting veth pair: $veth1"
    ip link delete "$veth1" >>"$LOG_FILE" 2>&1 || true
    
    log "INFO" "Removing routes"
    ip route del "$cidr2" dev "$bridge1" >>"$LOG_FILE" 2>&1 || true
    ip route del "$cidr1" dev "$bridge2" >>"$LOG_FILE" 2>&1 || true
    
    local config=$(load_config)
    config=$(echo "$config" | jq ".vpcs[\"$vpc1\"].peerings -= [\"$vpc2\"]")
    config=$(echo "$config" | jq ".vpcs[\"$vpc2\"].peerings -= [\"$vpc1\"]")
    save_config "$config"
    
    log "INFO" "Peering deleted between $vpc1 and $vpc2"
}