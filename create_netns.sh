#!/usr/bin/bash

if [ "$#" -ne 5 ]
then
	echo "Usage: \`create_netns.sh <new_netns_name> <ifaces_in_netns> <default_iface_for_netns> <virtual_eth_in_netns>=<network> <virtual_eth_outside_netns>=<network>\`"
	echo "Example: \`create_netns.sh vpnns eth0,tun0 tun0 vethinvpn=10.0.1.0/24 vethoutvpn=10.0.2.0/24\`"
	exit 1
fi

netns="$1"

# I can't figure out how to use `mapfile` or `read -a` or `readarray` to make this work otherwise
# shellcheck disable=2207
ifaces=($(echo "$2" | tr ',' ' '))

default_iface="$3"

vethinns="$(echo "$4" | cut -d '=' -f1)"
vethinns_network="$(echo "$4" | cut -d '=' -f2)"
vethoutns="$(echo "$5" | cut -d '=' -f1)"
vethoutns_network="$(echo "$5" | cut -d '=' -f2)"

set -euxo pipefail

# get the ip address associated with the interfaces
declare -A inets
for iface in "${ifaces[@]}"
do
	inets[$iface]="$(ip a show dev "$iface" | grep -Po 'inet \K[^ ]+')"
done

# create the namespace
sudo ip netns add "$netns"

# move the interface into the namespace
for iface in "${!inets[@]}"
do
	sudo ip link set "$iface" netns "$netns"

	# make sure tun0 is running on the correct ip, I guess?
	sudo ip -n "$netns" addr add "${inets[$iface]}" dev "$iface"

	# make sure tun0 is running in the vpnns
	sudo ip -n "$netns" link set "$iface" up
done

# make sure all traffic in the netns is running through the default iface
sudo ip -n "$netns" route add default dev "$default_iface"

# create fake interfaces to allow us to communicate between the main netns and vpnns
sudo ip link add "$vethinns" type veth peer name "$vethoutns"

# need to start them before trying to add routes
sudo ip link set "$vethinns" up
sudo ip link set "$vethoutns" up

# move vethinvpn to inside vpnns
sudo ip link set "$vethinns" netns "$netns"

# once more for good measure, now that it's inside a different netns?
sudo ip -n "$netns" link set "$vethinns" up

# tell vpnns that all messages to 10.0.1.0/24 go to vethinvpn
sudo ip -n "$netns" addr add "$vethinns_network" dev "$vethinns"

# do we need to do this? idk
sudo ip -n "$netns" route add "$vethoutns_network" dev "$vethinns"

# make sure loopback is working
sudo ip link set lo up

# same thing as vethinvpn inside vpnns, but this time with vethoutvpn in the main ns.
# this creates the idea of netns existing at 10.0.2.0/24 and the main one existing at 10.0.1.0/24
sudo ip addr add "$vethoutns_network" dev "$vethoutns"
sudo ip route add "$vethinns_network" dev "$vethoutns"
