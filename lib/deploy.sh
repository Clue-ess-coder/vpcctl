#!/bin/bash

deploy_server() {
    local vpc_name=""
    local subnet_name=""
    local port=80
    local manual_ip=""
    
    # Parse arguments
    local args=("$@")
    local i=0
    
    # vpc_name
    if [ $# -gt $i ]; then
        vpc_name="${args[$i]}"
        i=$((i + 1))
    fi
    
    # subnet_name
    if [ $# -gt $i ]; then
        subnet_name="${args[$i]}"
        i=$((i + 1))
    fi
    
    # Check if next argument is --ip or a port number
    if [ $# -gt $i ]; then
        if [ "${args[$i]}" = "--ip" ]; then
            # --ip flag found, get IP address
            i=$((i + 1))
            if [ $# -gt $i ]; then
                manual_ip="${args[$i]}"
            fi
        else
            port="${args[$i]}"
            i=$((i + 1))
            
            if [ $# -gt $i ] && [ "${args[$i]}" = "--ip" ]; then
                i=$((i + 1))
                if [ $# -gt $i ]; then
                    manual_ip="${args[$i]}"
                fi
            fi
        fi
    fi

    [ -z "$vpc_name" ] && vpc_name="$VPC_NAME"
    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"
    
    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl deploy [nginx] <vpc> <subnet> [port] [--ip <ip-address>]"
        log "ERROR" "Example: vpcctl deploy my-vpc public 8080"
        log "ERROR" "Example: vpcctl deploy my-vpc public 8080 --ip 10.0.1.50"
        log "ERROR" "Example: vpcctl deploy my-vpc public --ip 10.0.1.50  (port defaults to 80)"
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
    
    if ! command -v nginx &> /dev/null; then
        log "ERROR" "nginx not found. Install with: apt-get install -y nginx"
        exit 1
    fi
    
    log "INFO" "Deploying nginx server in subnet $subnet_name on port $port"
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    local veth_ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].veth_ns" "$CONFIG_FILE")
    local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
    local prefix=${cidr#*/}
    
    local next_ip
    if [ -n "$manual_ip" ]; then
        if ! ip_in_cidr "$manual_ip" "$cidr"; then
            log "ERROR" "Manual IP $manual_ip is not within subnet CIDR $cidr"
            exit 1
        fi
        
        if is_ip_allocated "$vpc_name" "$subnet_name" "$manual_ip"; then
            log "ERROR" "Manual IP $manual_ip is already allocated"
            exit 1
        fi
        
        next_ip="$manual_ip"
        log "INFO" "Using manually specified IP: $next_ip"
    else
        next_ip=$(get_next_ip_safe "$vpc_name" "$subnet_name")
        if [ $? -ne 0 ] || [ -z "$next_ip" ]; then
            log "ERROR" "Failed to allocate IP address. Subnet may be exhausted."
            exit 1
        fi
        log "INFO" "Automatically allocated IP: $next_ip"
    fi

    local server_name="nginx-$(date +%s)"
    local nginx_dir="/tmp/vpcctl-${vpc_name}-${subnet_name}-${server_name}"
    
    log "INFO" "Assigning IP: $next_ip to interface $veth_ns in namespace $ns"
    
    ip netns exec "$ns" ip addr add "$next_ip/$prefix" dev "$veth_ns"
    
    if ! ip netns exec "$ns" ip addr show "$veth_ns" | grep -q "$next_ip"; then
        log "ERROR" "Failed to assign IP $next_ip to interface $veth_ns"
        exit 1
    fi
    
    log "INFO" "IP assigned successfully"
    log "INFO" "Server name: $server_name"
    
    mkdir -p "$nginx_dir"
    
    cat > "$nginx_dir/nginx.conf" << EOF
daemon off;
worker_processes 1;
error_log $nginx_dir/error.log;
pid $nginx_dir/nginx.pid;

events {
    worker_connections 1024;
}

http {
    access_log $nginx_dir/access.log;
    
    server {
        listen $next_ip:$port;
        
        location / {
            return 200 "VPC Test Server\n\nVPC: $vpc_name\nSubnet: $subnet_name\nIP: $next_ip\nPort: $port\nServer: $server_name\n\nNginx is serving this response!\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF
    
    log "INFO" "Starting nginx on $next_ip:$port"
    
    ip netns exec "$ns" nginx -c "$nginx_dir/nginx.conf" > "$nginx_dir/stdout.log" 2>&1 &
    local pid=$!
    
    sleep 2
    
    if ! kill -0 "$pid" >>"$LOG_FILE" 2>&1; then
        log "ERROR" "Nginx failed to start. Check logs:"
        cat "$nginx_dir/error.log" 2>/dev/null || echo "No error log found"
        cat "$nginx_dir/stdout.log" 2>/dev/null || echo "No stdout log found"
        exit 1
    fi
    
    if ! ip netns exec "$ns" netstat -tlnp 2>/dev/null | grep -q ":$port"; then
        log "ERROR" "Nginx not listening on port $port"
        cat "$nginx_dir/error.log" 2>/dev/null
        exit 1
    fi
    
    log "INFO" "Server started with PID: $pid"
    
    local config=$(load_config)

    local current_next_ip=$(get_next_ip "$vpc_name" "$subnet_name")
    local new_next_ip
    
    if [ -n "$manual_ip" ]; then
        local manual_next=$(increment_ip "$next_ip")
        if [ -n "$current_next_ip" ] && [ "$current_next_ip" != "null" ]; then
            # Compare IPs and use the larger one
            local manual_int=$(ip_to_int "$manual_next")
            local current_int=$(ip_to_int "$current_next_ip")
            if [ $manual_int -gt $current_int ]; then
                new_next_ip="$manual_next"
            else
                new_next_ip="$current_next_ip"
            fi
        else
            new_next_ip="$manual_next"
        fi
        config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].next_ip = \"$new_next_ip\"")
    else
        new_next_ip=$(increment_ip "$next_ip")
        config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].next_ip = \"$new_next_ip\"")
    fi

    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips[\"$next_ip\"] = {
        \"name\": \"$server_name\",
        \"port\": $port,
        \"pid\": $pid,
        \"nginx_dir\": \"$nginx_dir\",
        \"manual_ip\": $([ -n \"$manual_ip\" ] && echo \"true\" || echo \"false\")
    }")
    save_config "$config"
    
    log "INFO" "Server deployed successfully"
    
    echo ""
    echo "Server Details:"
    echo "  VPC: $vpc_name"
    echo "  Subnet: $subnet_name"
    echo "  IP: $next_ip"
    echo "  Port: $port"
    echo "  PID: $pid"
    echo "  Config: $nginx_dir/nginx.conf"
    echo ""
    echo "Test:"
    echo "  curl http://$next_ip:$port"
}


run_in_subnet() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name=$2
    shift 2
    
    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"

    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ] || [ $# -eq 0 ]; then
        log "ERROR" "Usage: vpcctl run <vpc> <subnet> <command> [args...]"
        log "ERROR" "Example: vpcctl run my-vpc public-subnet python3 -m http.server 8080"
        log "ERROR" "Example: vpcctl run my-vpc public-subnet bash -c \"echo 'hello world'\""
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
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    
    local cmd_str="$*"
    log "INFO" "Running command in subnet $subnet_name (namespace: $ns)"
    log "INFO" "Command: $cmd_str"

    local cmd=""
    for arg in "$@"; do
        arg_escaped=$(printf '%s\n' "$arg" | sed "s/'/'\"'\"'/g")
        if [ -z "$cmd" ]; then
            cmd="'$arg_escaped'"
        else
            cmd="$cmd '$arg_escaped'"
        fi
    done

    eval "ip netns exec \"$ns\" $cmd"
}

deploy_python_server() {
    local vpc_name=${1:-$VPC_NAME}
    local subnet_name=$2
    local port=${3:-8000}
    
    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"

    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl deploy python <vpc> <subnet> <port>"
        log "ERROR" "Or set environment variables: VPC_NAME, PUBLIC_SUBNET/PRIVATE_SUBNET"
        exit 1
    fi
    
    if ! command -v python3 &> /dev/null; then
        log "ERROR" "python3 not found"
        exit 1
    fi
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].namespace" "$CONFIG_FILE")
    local cidr=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].cidr" "$CONFIG_FILE")
    local veth_ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].veth_ns" "$CONFIG_FILE")
    local prefix=${cidr#*/}
    
    local next_ip=$(get_next_ip_safe "$vpc_name" "$subnet_name")
    if [ $? -ne 0 ] || [ -z "$next_ip" ]; then
        log "ERROR" "Failed to allocate IP address"
        exit 1
    fi
    
    log "INFO" "Assigning IP: $next_ip to interface $veth_ns"
    ip netns exec "$ns" ip addr add "$next_ip/$prefix" dev "$veth_ns" >>"$LOG_FILE" 2>&1 || true
    
    log "INFO" "Starting Python HTTP server on $next_ip:$port"
    ip netns exec "$ns" python3 -m http.server "$port" --bind "$next_ip" > "/tmp/vpcctl-python-${vpc_name}-${subnet_name}.log" 2>&1 &
    local pid=$!
    
    sleep 1
    if ! kill -0 "$pid" >>"$LOG_FILE" 2>&1; then
        log "ERROR" "Python server failed to start"
        exit 1
    fi

    local new_next_ip=$(increment_ip "$next_ip")
    local config=$(load_config)
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].next_ip = \"$new_next_ip\"")
    config=$(echo "$config" | jq ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips[\"$next_ip\"] = {
        \"name\": \"python-server\",
        \"port\": $port,
        \"pid\": $pid,
        \"type\": \"python\"
    }")
    save_config "$config"
    
    log "INFO" "Python server started on http://$next_ip:$port (PID: $pid)"
}

test_connectivity() {
    local vpc_name=${1:-$VPC_NAME}
    local source_subnet=$2
    local target_ip=$3
    local target_port=${4:-80}
    local protocol=${5:-tcp}
    
    [ -z "$source_subnet" ] && source_subnet="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"

    if [ -z "$vpc_name" ] || [ -z "$source_subnet" ] || [ -z "$target_ip" ]; then
        log "ERROR" "Usage: vpcctl test <vpc> <source-subnet> <target-ip> [port] [protocol]"
        log "ERROR" "Example: vpcctl test my-vpc public-subnet 10.0.1.10 8080"
        exit 1
    fi
    
    if ! subnet_exists "$vpc_name" "$source_subnet"; then
        log "ERROR" "Subnet $source_subnet does not exist in VPC $vpc_name"
        exit 1
    fi
    
    local ns=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$source_subnet\"].namespace" "$CONFIG_FILE")
    
    log "INFO" "Testing connectivity from $source_subnet to $target_ip:$target_port ($protocol)"
    
    case "$protocol" in
        tcp)
            if ip netns exec "$ns" timeout 3 bash -c "echo > /dev/tcp/$target_ip/$target_port" >>"$LOG_FILE" 2>&1; then
                log "INFO" "TCP connection to $target_ip:$target_port successful"
                return 0
            else
                log "ERROR" "TCP connection to $target_ip:$target_port failed"
                return 1
            fi
            ;;
        udp)
            if ip netns exec "$ns" timeout 2 nc -u -z "$target_ip" "$target_port" >>"$LOG_FILE" 2>&1; then
                log "INFO" "UDP connection to $target_ip:$target_port successful"
                return 0
            else
                log "WARN" "UDP test inconclusive (UDP is connectionless)"
                return 0
            fi
            ;;
        icmp|ping)
            if ip netns exec "$ns" ping -c 3 -W 2 "$target_ip" > /dev/null 2>&1; then
                log "INFO" "ICMP ping to $target_ip successful"
                return 0
            else
                log "ERROR" "ICMP ping to $target_ip failed"
                return 1
            fi
            ;;
        *)
            log "ERROR" "Unknown protocol: $protocol (supported: tcp, udp, icmp, ping)"
            return 1
            ;;
    esac
}

get_service_ip() {
    local vpc_name=${1:-VPC_NAME}
    local subnet_name=$2
    local service_name=${3:-nginx}

    [ -z "$subnet_name" ] && subnet_name="${PUBLIC_SUBNET_NAME:-$PRIVATE_SUBNET_NAME}"

    if [ -z "$vpc_name" ] || [ -z "$subnet_name" ]; then
        log "ERROR" "Usage: vpcctl get-ip <vpc> <subnet> [service-name]"
        log "ERROR" "  Or set environment variables: VPC_NAME, PUBLIC_SUBNET_NAME/PRIVATE_SUBNET_NAME"
        exit 1
    fi

    local ip=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips | to_entries[] | select(.value.name | contains(\"$service_name\")) | .key" "$CONFIG_FILE" | head -n1)
    
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        ip=$(jq -r ".vpcs[\"$vpc_name\"].subnets[\"$subnet_name\"].allocated_ips | keys[0]" "$CONFIG_FILE")
    fi
    
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        log "ERROR" "No allocated IPs found in subnet $subnet_name"
        exit 1
    fi
    
    echo "$ip"
}
