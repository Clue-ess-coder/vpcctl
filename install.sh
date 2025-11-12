#!/usr/bin/env bash

echo 'export PATH="$HOME/.vpcctl/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

chmod +x $HOME/.vpcctl/bin/vpcctl
chmod +x $HOME/.vpcctl/bin/vpcctl-cleanup
