#!/bin/bash
set -e

VPCCTL="$HOME/.vpcctl/bin/vpcctl"
CONFIG_FILE="$HOME/.vpcctl/config.json"

echo "=========================================="
echo "vpcctl Firewall Test"
echo "=========================================="
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up test resources..."
    $VPCCTL rm vpc test-fw-vpc >>"$LOG_FILE" 2>&1 || true
	rm -rf /tmp/test-*.json
	cat > "$CONFIG_FILE" << EOF
{
  "vpcs": {},
  "settings": {
    "ip_allocation": {
      "start_offset": 10,
      "reserved_ips": ["0", "1", "2", "255"]
    },
    "limits": {
      "max_vpcs": 50,
      "max_subnets_per_vpc": 100
    }
  }
}
EOF
    echo "Cleanup complete"
}

# Set trap to cleanup on exit
trap cleanup EXIT

echo "Creating test VPC and subnet"
echo "============================"
echo ""
$VPCCTL create vpc test-fw-vpc 10.10.0.0/16
$VPCCTL create subnet test-fw-vpc public 10.10.1.0/24 public
$VPCCTL create subnet test-fw-vpc private 10.10.2.0/24 private
echo ""

echo "Deploying nginx servers in public and private subnets"
echo "======================================================"
echo ""
$VPCCTL deploy nginx test-fw-vpc public 8080
PUBLIC_IP=$($VPCCTL get-ip test-fw-vpc public)
echo "Public subnet server at $PUBLIC_IP:8080"

$VPCCTL deploy nginx test-fw-vpc private 8081
PRIVATE_IP=$($VPCCTL get-ip test-fw-vpc private)
echo "Private subnet server at $PRIVATE_IP:8081"
echo ""

echo "Testing connectivity before adding firewall rules"
echo "=================================================="
echo ""
echo "Testing HTTP to public subnet"
$VPCCTL test test-fw-vpc public $PUBLIC_IP 8080 tcp && echo "Public HTTP accessible" || echo "Public HTTP failed"

echo "Testing connectivity between subnets"
$VPCCTL run test-fw-vpc public curl -s -m 2 http://$PRIVATE_IP:8081 > /dev/null && echo "Inter-subnet communication established" || echo "Inter-subnet communication failed"
echo ""

echo "Applying firewall rule to DENY SSH on public subnet"
echo "===================================================="
echo ""
cat > /tmp/test-deny-ssh.json << 'EOF'
{
  "mode": "permissive",
  "enable_logging": false,
  "ingress": [
    {
      "port": 22,
      "protocol": "tcp",
      "action": "deny"
    },
    {
      "port": 8080,
      "protocol": "tcp",
      "action": "allow"
    }
  ]
}
EOF
echo "Firewall rule:"
cat /tmp/test-deny-ssh.json

$VPCCTL firewall test-fw-vpc public /tmp/test-deny-ssh.json
echo ""

echo "Verifying active firewall rules"
echo "================================"
echo ""
$VPCCTL firewall show test-fw-vpc public
echo ""

echo "Testing after firewall rules applied"
echo "===================================="
echo ""
echo "Testing HTTP to public subnet"
$VPCCTL test test-fw-vpc public $PUBLIC_IP 8080 tcp && echo "Public HTTP accesible" || echo "Public HTTP Blocked"

echo "Testing SSH to public subnet"
$VPCCTL test test-fw-vpc public $PUBLIC_IP 22 tcp && echo "SSH not blocked" || echo "SSH blocked"
echo ""

echo "Testing RESTRICTIVE mode with source filtering"
echo "================================================"
echo ""
cat > /tmp/test-restrictive.json << 'EOF'
{
  "mode": "restrictive",
  "enable_logging": true,
  "ingress": [
    {
      "port": 8080,
      "protocol": "tcp",
      "source": "10.10.2.0/24",
      "action": "allow"
    },
    {
      "protocol": "icmp",
      "icmp_type": 8,
      "action": "allow"
    }
  ],
  "egress": [
    {
      "port": 8081,
      "protocol": "tcp",
      "destination": "10.10.2.0/24",
      "action": "allow"
    },
    {
      "protocol": "icmp",
      "action": "allow"
    }
  ]
}
EOF
echo "Firewall rule:"
cat /tmp/test-restrictive.json

$VPCCTL firewall test-fw-vpc public /tmp/test-restrictive.json
echo "Successfully applied restrictive policy to public subnet"
echo ""

echo "Testing ping from public to private (ICMP/ping allowed)"
$VPCCTL run test-fw-vpc public ping -c 2 $PRIVATE_IP > /dev/null 2>&1 && echo "Ping successful" || echo "Ping blocked"

echo "Testing HTTP from public to private (egress allowed)"
$VPCCTL run test-fw-vpc public curl -s -m 2 http://$PRIVATE_IP:8081 > /dev/null 2>&1 && echo "HTTP to private allowed" || echo "HTTP to private blocked"
echo ""

echo "Testing VPC-level firewall"
echo "============================"
echo ""
cat > /tmp/test-vpc-policy.json << 'EOF'
{
  "mode": "permissive",
  "enable_logging": false,
  "ingress": [
    {
      "protocol": "icmp",
      "action": "allow"
    }
  ],
  "egress": [
    {
      "port": 443,
      "protocol": "tcp",
      "action": "deny"
    }
  ]
}
EOF
echo "Firewall rule:"
cat /tmp/test-vpc-policy.json

$VPCCTL firewall vpc test-fw-vpc /tmp/test-vpc-policy.json
echo "Applied VPC-level policy to all subnets"
echo ""

echo "Verifying successful policy application to public subnet"
echo "========================================================"
$VPCCTL firewall show test-fw-vpc public | grep -A 5 "OUTPUT Chain"
echo ""

echo "Verifying successful policy application to private subnet"
echo "=========================================================="
$VPCCTL firewall show test-fw-vpc private | grep -A 5 "OUTPUT Chain"
echo ""

echo "Applying ICMP(ping) deny rule to private subnet"
echo "================================================="
echo ""
cat > /tmp/test-icmp.json << 'EOF'
{
  "mode": "permissive",
  "enable_logging": false,
  "ingress": [
    {
      "protocol": "icmp",
      "icmp_type": 8,
      "action": "deny"
    }
  ]
}
EOF

$VPCCTL firewall test-fw-vpc private /tmp/test-icmp.json
echo "Successfully applied ICMP deny rule to private subnet"

echo "Testing ping to private subnet"
$VPCCTL run test-fw-vpc public ping -c 2 $PRIVATE_IP > /dev/null 2>&1 && echo "Ping unblocked" || echo "Ping blocked"
echo ""

echo "Removing firewall rules"
echo "========================"
echo ""
$VPCCTL firewall remove test-fw-vpc public
echo "Removed firewall from public subnet"

$VPCCTL firewall vpc remove test-fw-vpc
echo "Removed VPC-level firewall"
echo ""

echo "Verifying rules are removed"
e
echo ""
echo "Public subnet rules (should be default ACCEPT)"
$VPCCTL firewall show test-fw-vpc public | grep "policy"
echo ""

echo "=========================================="
echo "Firewall Test Complete"
echo "=========================================="
