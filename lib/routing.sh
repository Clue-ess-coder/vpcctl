#!/bin/bash

enable_nat() {
    local cidr=$1
    local internet_iface=${INTERNET_INTERFACE:-$(get_internet_interface)}
    
    if [ -z "$internet_iface" ]; then
        log "ERROR" "No internet interface found. Set INTERNET_INTERFACE or ensure default route exists"
        return 1
    fi
    
    log "INFO" "Enabling NAT for $cidr via $internet_iface"
    
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    iptables -C FORWARD -s "$cidr" -o "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1 || \
        iptables -I FORWARD 1 -s "$cidr" -o "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1

    iptables -C FORWARD -d "$cidr" -i "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1 || \
        iptables -I FORWARD 1 -d "$cidr" -i "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1
    
    iptables -t nat -C POSTROUTING -s "$cidr" -o "$internet_iface" -j MASQUERADE >>"$LOG_FILE" 2>&1 || \
        iptables -t nat -A POSTROUTING -s "$cidr" -o "$internet_iface" -j MASQUERADE >>"$LOG_FILE" 2>&1
    
    log "INFO" "NAT enabled for $cidr"
}

disable_nat() {
    local cidr=$1
    local internet_iface=$(get_internet_interface)
    
    if [ -z "$internet_iface" ]; then
        return 0
    fi
    
    log "INFO" "Disabling NAT for $cidr"

    iptables -D FORWARD -s "$cidr" -o "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1 || true
    iptables -D FORWARD -d "$cidr" -i "$internet_iface" -j ACCEPT >>"$LOG_FILE" 2>&1 || true

    iptables -t nat -D POSTROUTING -s "$cidr" -o "$internet_iface" -j MASQUERADE >>"$LOG_FILE" 2>&1 || true
    
    log "INFO" "NAT disabled for $cidr"
}
