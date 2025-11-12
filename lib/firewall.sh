#!/bin/bash

validate_rule() {
    local rule=$1
    local rule_type=$2
    
    local port=$(echo "$rule" | jq -r '.port // empty')
    local protocol=$(echo "$rule" | jq -r '.protocol // "tcp"')
    local action=$(echo "$rule" | jq -r '.action // "allow"')

    if [ -n "$port" ]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log "ERROR" "Invalid port number: $port (must be 1-65535)"
            return 1
        fi
    fi
    
    if [[ ! "$protocol" =~ ^(tcp|udp|icmp|all)$ ]]; then
        log "ERROR" "Invalid protocol: $protocol (must be tcp, udp, icmp, or all)"
        return 1
    fi
    
    if [[ ! "$action" =~ ^(allow|accept|deny|block|drop|reject)$ ]]; then
        log "ERROR" "Invalid action: $action (must be allow, accept, deny, block, drop, or reject)"
        return 1
    fi
    
    if [ "$protocol" = "icmp" ] && [ -n "$port" ]; then
        log "WARN" "ICMP protocol doesn't use ports, ignoring port $port"
    fi
    
    return 0
}

apply_ingress_rules() {
    local ns=$1
    local ingress_rules=$2
    
    if [ -z "$ingress_rules" ]; then
        return 0
    fi
    
    log "INFO" "Applying ingress rules"
    while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        
        if ! validate_rule "$rule" "ingress"; then
            log "WARN" "Skipping invalid ingress rule: $rule"
            continue
        fi
        
        local port=$(echo "$rule" | jq -r '.port // empty')
        local protocol=$(echo "$rule" | jq -r '.protocol // "tcp"')
        local action=$(echo "$rule" | jq -r '.action // "allow"')
        local source=$(echo "$rule" | jq -r '.source // empty')
        local icmp_type=$(echo "$rule" | jq -r '.icmp_type // empty')
        
        local target
        case "$action" in
            allow|accept)
                target="ACCEPT"
                ;;
            deny|block|drop)
                target="DROP"
                ;;
            reject)
                target="REJECT"
                ;;
        esac
        
        local ipt_cmd="ip netns exec \"$ns\" iptables -A INPUT"
        
        if [ "$protocol" = "icmp" ]; then
            ipt_cmd="$ipt_cmd -p icmp"
            if [ -n "$icmp_type" ] && [ "$icmp_type" != "null" ]; then
                ipt_cmd="$ipt_cmd --icmp-type $icmp_type"
            fi
        elif [ "$protocol" = "all" ]; then
            if [ -n "$port" ]; then
                log "WARN" "Port specified with protocol 'all', ignoring port"
            fi
        else
            ipt_cmd="$ipt_cmd -p \"$protocol\""
            if [ -n "$port" ]; then
                ipt_cmd="$ipt_cmd --dport \"$port\""
            fi
        fi
        
        if [ -n "$source" ] && [ "$source" != "null" ]; then
            ipt_cmd="$ipt_cmd -s \"$source\""
        fi
        
        ipt_cmd="$ipt_cmd -j \"$target\""
        
        log "INFO" "Adding ingress rule: $protocol ${port:+port $port }from ${source:-any} -> $action"
        eval "$ipt_cmd"
    done <<< "$ingress_rules"
}

apply_egress_rules() {
    local ns=$1
    local egress_rules=$2
    
    if [ -z "$egress_rules" ]; then
        return 0
    fi
    
    log "INFO" "Applying egress rules"
    while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        
        if ! validate_rule "$rule" "egress"; then
            log "WARN" "Skipping invalid egress rule: $rule"
            continue
        fi
        
        local port=$(echo "$rule" | jq -r '.port // empty')
        local protocol=$(echo "$rule" | jq -r '.protocol // "tcp"')
        local action=$(echo "$rule" | jq -r '.action // "allow"')
        local destination=$(echo "$rule" | jq -r '.destination // empty')
        local icmp_type=$(echo "$rule" | jq -r '.icmp_type // empty')
        
        local target
        case "$action" in
            allow|accept)
                target="ACCEPT"
                ;;
            deny|block|drop)
                target="DROP"
                ;;
            reject)
                target="REJECT"
                ;;
        esac
        
        local ipt_cmd="ip netns exec \"$ns\" iptables -A OUTPUT"
        
        if [ "$protocol" = "icmp" ]; then
            ipt_cmd="$ipt_cmd -p icmp"

            if [ -n "$icmp_type" ] && [ "$icmp_type" != "null" ]; then
                ipt_cmd="$ipt_cmd --icmp-type $icmp_type"
            fi
        elif [ "$protocol" = "all" ]; then
            if [ -n "$port" ]; then
                log "WARN" "Port specified with protocol 'all', ignoring port"
            fi
        else
            ipt_cmd="$ipt_cmd -p \"$protocol\""
            if [ -n "$port" ]; then
                ipt_cmd="$ipt_cmd --dport \"$port\""
            fi
        fi
        
        if [ -n "$destination" ] && [ "$destination" != "null" ]; then
            ipt_cmd="$ipt_cmd -d \"$destination\""
        fi
        
        ipt_cmd="$ipt_cmd -j \"$target\""
        
        log "INFO" "Adding egress rule: $protocol ${port:+port $port }to ${destination:-any} -> $action"
        eval "$ipt_cmd"
    done <<< "$egress_rules"
}

apply_forward_rules() {
    local ns=$1
    local forward_rules=$2
    
    if [ -z "$forward_rules" ]; then
        return 0
    fi
    
    log "INFO" "Applying forward rules"
    while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        
        if ! validate_rule "$rule" "forward"; then
            log "WARN" "Skipping invalid forward rule: $rule"
            continue
        fi
        
        local protocol=$(echo "$rule" | jq -r '.protocol // "all"')
        local action=$(echo "$rule" | jq -r '.action // "allow"')
        local source=$(echo "$rule" | jq -r '.source // empty')
        local destination=$(echo "$rule" | jq -r '.destination // empty')
        
        local target
        case "$action" in
            allow|accept)
                target="ACCEPT"
                ;;
            deny|block|drop)
                target="DROP"
                ;;
            reject)
                target="REJECT"
                ;;
        esac
        
        local ipt_cmd="ip netns exec \"$ns\" iptables -A FORWARD"
        
        if [ "$protocol" != "all" ]; then
            ipt_cmd="$ipt_cmd -p \"$protocol\""
        fi
        
        if [ -n "$source" ] && [ "$source" != "null" ]; then
            ipt_cmd="$ipt_cmd -s \"$source\""
        fi
        
        if [ -n "$destination" ] && [ "$destination" != "null" ]; then
            ipt_cmd="$ipt_cmd -d \"$destination\""
        fi
        
        ipt_cmd="$ipt_cmd -j \"$target\""
        
        log "INFO" "Adding forward rule: $protocol from ${source:-any} to ${destination:-any} -> $action"
        eval "$ipt_cmd"
    done <<< "$forward_rules"
}

apply_firewall() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name=$2
    local policy_file=$3

    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"
    
    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ] || [ -z "$policy_file" ]; then
        log "ERROR" "Usage: vpcctl firewall <vpc> <subnet> <policy-file>"
        log "ERROR" "Or set environment variables: VPC_NAME, PUBLIC_SUBNET/PRIVATE_SUBNET"
        exit 1
    fi
    
    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name does not exist in VPC $vpc_name"
        exit 1
    fi
    
    if [ ! -f "$policy_file" ]; then
        log "ERROR" "Policy file not found: $policy_file"
        exit 1
    fi
    
    if ! jq empty "$policy_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON in policy file: $policy_file"
        exit 1
    fi
    
    log "INFO" "Applying firewall rules to subnet $subnet_name in VPC $vpc_name"
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    
    local subnet_cidr=$(jq -r '.subnet // empty' "$policy_file")
    local policy_mode=$(jq -r '.mode // "permissive"' "$policy_file")
    local enable_logging=$(jq -r '.enable_logging // false' "$policy_file")
    local ingress_rules=$(jq -c '.ingress[]? // empty' "$policy_file" 2>/dev/null)
    local egress_rules=$(jq -c '.egress[]? // empty' "$policy_file" 2>/dev/null)
    local forward_rules=$(jq -c '.forward[]? // empty' "$policy_file" 2>/dev/null)
    
    if [ -n "$subnet_cidr" ] && [ "$subnet_cidr" != "null" ]; then
        local actual_cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
        if [ "$subnet_cidr" != "$actual_cidr" ]; then
            log "WARN" "Policy subnet ($subnet_cidr) doesn't match actual subnet CIDR ($actual_cidr)"
            log "WARN" "Proceeding with policy but consider updating policy file"
        fi
    fi
    
    log "INFO" "Clearing existing rules in namespace $ns"
    ip netns exec "$ns" iptables -F INPUT >>"$LOG_FILE" 2>&1 || true
    ip netns exec "$ns" iptables -F OUTPUT >>"$LOG_FILE" 2>&1 || true
    ip netns exec "$ns" iptables -F FORWARD >>"$LOG_FILE" 2>&1 || true
    
    if [ "$policy_mode" = "restrictive" ]; then
        log "INFO" "Setting restrictive default policies (default DENY)"

        ip netns exec "$ns" iptables -P INPUT DROP
        ip netns exec "$ns" iptables -P OUTPUT DROP
        ip netns exec "$ns" iptables -P FORWARD DROP
        
        log "INFO" "Allowing established/related connections (stateful tracking)"
        ip netns exec "$ns" iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip netns exec "$ns" iptables -I OUTPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip netns exec "$ns" iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        
        ip netns exec "$ns" iptables -I INPUT 1 -i lo -j ACCEPT
        ip netns exec "$ns" iptables -I OUTPUT 1 -o lo -j ACCEPT
    else
        log "INFO" "Setting permissive default policies (default ALLOW)"
        ip netns exec "$ns" iptables -P INPUT ACCEPT
        ip netns exec "$ns" iptables -P OUTPUT ACCEPT
        ip netns exec "$ns" iptables -P FORWARD ACCEPT
    fi
    
    apply_ingress_rules "$ns" "$ingress_rules"
    apply_egress_rules "$ns" "$egress_rules"
    apply_forward_rules "$ns" "$forward_rules"
    
    if [ "$enable_logging" = "true" ]; then
        log "INFO" "Enabling firewall logging"
        if [ "$policy_mode" = "restrictive" ]; then
            ip netns exec "$ns" iptables -A INPUT -j LOG --log-prefix "FW-DROP-IN: " --log-level 4 >>"$LOG_FILE" 2>&1 || true
            ip netns exec "$ns" iptables -A OUTPUT -j LOG --log-prefix "FW-DROP-OUT: " --log-level 4 >>"$LOG_FILE" 2>&1 || true
            ip netns exec "$ns" iptables -A FORWARD -j LOG --log-prefix "FW-DROP-FWD: " --log-level 4 >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    
    local config=$(load_config)
    local policy_content=$(cat "$policy_file")
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].firewall_policy = $policy_content")
    save_config "$config"
    
    log "INFO" "Firewall rules applied and persisted successfully"
    log "INFO" "Mode: $policy_mode | Logging: $enable_logging"
}

apply_vpc_firewall() {
    local vpc_name=${1:-$VPC_NAME}
    local policy_file=$2
    
    if [ -z "$vpc_name" ] || [ -z "$policy_file" ]; then
        log "ERROR" "Usage: vpcctl firewall vpc <vpc> <policy-file>"
        exit 1
    fi
    
    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    if [ ! -f "$policy_file" ]; then
        log "ERROR" "Policy file not found: $policy_file"
        exit 1
    fi
    
    log "INFO" "Applying VPC-level firewall to all subnets in $vpc_name"
    
    local subnets=$(jq -r ".vpcs[\"$vpc_name\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$subnets" ]; then
        log "WARN" "No subnets found in VPC $vpc_name"
        return 0
    fi
    
    for subnet in $subnets; do
        log "INFO" "Applying policy to subnet: $subnet"
        apply_firewall "$vpc_name" "$subnet" "$policy_file"
    done
    
    local config=$(load_config)
    local policy_content=$(cat "$policy_file")
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].vpc_firewall_policy = $policy_content")
    save_config "$config"
    
    log "INFO" "VPC-level firewall applied successfully to all subnets"
}

remove_firewall() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name=$2

    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"
    
    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl firewall remove <vpc> <subnet>"
        exit 1
    fi
    
    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name does not exist in VPC $vpc_name"
        exit 1
    fi
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    
    log "INFO" "Removing firewall rules from subnet $subnet_name"
    ip netns exec "$ns" iptables -F INPUT >>"$LOG_FILE" 2>&1 || true
    ip netns exec "$ns" iptables -F OUTPUT >>"$LOG_FILE" 2>&1 || true
    ip netns exec "$ns" iptables -F FORWARD >>"$LOG_FILE" 2>&1 || true
    
    ip netns exec "$ns" iptables -P INPUT ACCEPT
    ip netns exec "$ns" iptables -P OUTPUT ACCEPT
    ip netns exec "$ns" iptables -P FORWARD ACCEPT
    
    local config=$(load_config)
    config=$(echo "$config" | jq "del(.vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].firewall_policy)")
    save_config "$config"
    
    log "INFO" "Firewall rules removed successfully"
}

remove_vpc_firewall() {
    local vpc_name=${1:-$VPC_NAME}
    
    if [ -z "$vpc_name" ]; then
        log "ERROR" "Usage: vpcctl firewall vpc remove <vpc>"
        exit 1
    fi
    
    if ! vpc_exists "$vpc_name"; then
        log "ERROR" "VPC $vpc_name does not exist"
        exit 1
    fi
    
    log "INFO" "Removing VPC-level firewall from all subnets in $vpc_name"    
    local subnets=$(jq -r ".vpcs[\"$vpc_name\"].subnets | keys[]" "$CONFIG_FILE" 2>/dev/null)
    
    for subnet in $subnets; do
        log "INFO" "Removing policy from subnet: $subnet"
        remove_firewall "$vpc_name" "$subnet"
    done
    
    local config=$(load_config)
    config=$(echo "$config" | jq "del(.vpcs[\"$vpc_name\"].vpc_firewall_policy)")
    save_config "$config"
    
    log "INFO" "VPC-level firewall removed successfully"
}

show_firewall() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name=$2

    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"
    
    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl firewall show <vpc> <subnet>"
        exit 1
    fi
    
    if ! subnet_exists "$vpc_name" "$subnet_name"; then
        log "ERROR" "Subnet $subnet_name does not exist in VPC $vpc_name"
        exit 1
    fi
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    
    echo "Firewall rules for subnet $subnet_name in VPC $vpc_name (namespace: $ns)"
    echo ""
    echo "=== INPUT Chain ==="
    ip netns exec "$ns" iptables -L INPUT -n -v --line-numbers
    echo ""
    echo "=== OUTPUT Chain ==="
    ip netns exec "$ns" iptables -L OUTPUT -n -v --line-numbers
    echo ""
    echo "=== FORWARD Chain ==="
    ip netns exec "$ns" iptables -L FORWARD -n -v --line-numbers
}
