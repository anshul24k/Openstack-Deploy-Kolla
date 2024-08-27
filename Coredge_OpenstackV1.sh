#!/bin/bash

# Script to automate Kolla Ansible OpenStack deployment with a minimal globals.yml

echo "Welcome to the Kolla Ansible OpenStack Deployment Script"

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# Fetch and display OS version
OS_VERSION=$(lsb_release -d | awk -F"\t" '{print $2}')
echo "Detected OS: $OS_VERSION"

# Collect all user inputs
echo "Please provide the following information:"

read -p "Enter the IP addresses of the controller nodes (comma-separated): " CONTROLLER_IPS
read -p "Enter the IP addresses of the compute nodes (comma-separated): " COMPUTE_IPS
read -p "Enter the internal VIP address (kolla_internal_vip_address): " KOLLA_INTERNAL_VIP
read -p "Enter the management network interface name (e.g., eth0): " MGMT_INTERFACE
read -p "Enter the neutron interface name (e.g., eth1, bond0.210): " EXT_INTERFACE
read -p "Enter tunnel interface: " TUNNEL_INTERFACE 

# Collect NTP server IPs from the user
read -p "Enter NTP server IPs (comma-separated if multiple): " NTP_SERVERS

# Choose between ceos-01 and ceos-02, which will map to specific OpenStack versions
echo "Choose your environment:"
echo "1) ceos-01"
echo "2) ceos-02"
read -p "Enter your choice (1 or 2): " ENVIRONMENT_CHOICE

# Map the selected environment to the corresponding OpenStack version
if [ "$ENVIRONMENT_CHOICE" == "1" ]; then
  OPENSTACK_VERSION="2023.1"
elif [ "$ENVIRONMENT_CHOICE" == "2" ]; then
  OPENSTACK_VERSION="2023.2"
else
  echo "Invalid choice. Exiting."
  exit 1
fi

# Enable core services by default
ENABLE_SERVICES=("enable_cinder" "enable_glance" "enable_keystone" "enable_horizon" "enable_neutron" "enable_nova")

# Prompt user to disable services
echo "Core services are enabled by default."
echo "Select any service you want to disable by entering the corresponding number (comma-separated if multiple):"
echo "1) Cinder (Block Storage)"
echo "2) Glance (Image Service)"
echo "3) Keystone (Identity Service)"
echo "4) Horizon (Dashboard)"
echo "5) Neutron (Networking)"
echo "6) Nova (Compute)"
read -p "Enter your choices (or press Enter to skip): " DISABLE_CHOICE

DISABLE_LIST=()
if [ -n "$DISABLE_CHOICE" ]; then
  IFS=',' read -r -a DISABLE_LIST <<< "$DISABLE_CHOICE"
fi

# Prompt user to enable additional services
echo "Select any additional services you want to enable by entering the corresponding number (comma-separated if multiple):"
echo "1) Barbican (Key Manager)"
echo "2) Octavia (Load Balancer)"
read -p "Enter your choices (or press Enter to skip): " ENABLE_CHOICE

ENABLE_LIST=()
OCTAVIA_ENABLED="no"
OCTAVIA_CIDR=""
OCTAVIA_LB_INTERFACE=""
if [ -n "$ENABLE_CHOICE" ]; then
  IFS=',' read -r -a ENABLE_LIST <<< "$ENABLE_CHOICE"

  # Check if Octavia is enabled
  for ENABLE in "${ENABLE_LIST[@]}"; do
    if [ "$ENABLE" == "2" ]; then
      OCTAVIA_ENABLED="yes"
      read -p "Enter the load balancer network interface name: " OCTAVIA_LB_INTERFACE
      read -p "Enter the CIDR for Octavia (e.g., 10.10.12.0/24): " OCTAVIA_CIDR
      read -p "Enter the allocation pool start for Octavia: " OCTAVIA_POOL_START
      read -p "Enter the allocation pool end for Octavia: " OCTAVIA_POOL_END
      read -p "Enter the gateway IP for Octavia: " OCTAVIA_GATEWAY_IP
    fi
  done
fi

# Prompt for custom overrides
read -p "Are you using config overrides? (yes/no): " USE_CONFIG_OVERRIDES

# Prompt for block storage configuration
echo "Select your block storage configuration:"
echo "1) Ceph"
echo "2) External SAN Storage"
read -p "Enter your choice (1 or 2): " STORAGE_CHOICE

if [ "$STORAGE_CHOICE" == "2" ]; then
  read -p "Enter the SAN Rest URL (e.g., https://10.0.0.0:8080/deviceManager/rest/): " SAN_REST_URL
  read -p "Enter the SAN Username: " SAN_USERNAME
  read -sp "Enter the SAN Password: " SAN_PASSWORD
  echo  # Move to the next line after password input
  read -p "FC or iSCSI: " SAN_PROTOCOL
  read -p "Enter the SAN Product name (e.g., Dorado): " SAN_PRODUCT
  read -p "Enter the Host IPs (comma-separated): " SAN_HOST_IPS
fi

# Start the installation and deployment process

# Update package list and install dependencies
echo "Installing dependencies..."
sudo apt remove -y containerd.io
sudo apt update && sudo apt install -y python3-dev libffi-dev gcc libssl-dev python3-venv git docker.io python3-docker || { echo "Dependency installation failed"; exit 1; }

# Create a virtual environment and activate it
echo "Creating and activating virtual environment..."
python3 -m venv /opt/kolla-venv
source /opt/kolla-venv/bin/activate || { echo "Failed to activate virtual environment"; exit 1; }

# Upgrade pip in the virtual environment
echo "Upgrading pip..."
pip install -U pip || { echo "Pip upgrade failed"; exit 1; }

# Install requests version 2.31.0 explicitly
echo "Installing requests==2.31.0..."
pip install requests==2.31.0 || { echo "Failed to install requests 2.31.0"; exit 1; }

# Install the correct version of Ansible using pip
echo "Installing Ansible (ansible-core 2.15.x)..."
pip install 'ansible-core>=2.15,<2.16' || { echo "Ansible installation failed"; exit 1; }

# Install Kolla Ansible using pip
echo "Installing Kolla Ansible..."
pip install git+https://opendev.org/openstack/kolla-ansible@stable/$OPENSTACK_VERSION || { echo "Kolla Ansible installation failed"; exit 1; }

# Create the /etc/kolla directory if it doesn't exist
echo "Setting up Kolla configuration directory..."
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla

# Copy example configuration files
echo "Copying example configuration files..."
cp -r /opt/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla || { echo "Failed to copy example configuration files"; exit 1; }

# Copy the multinode inventory file
echo "Copying the multinode inventory file..."
cp /opt/kolla-venv/share/kolla-ansible/ansible/inventory/multinode . || { echo "Failed to copy inventory file"; exit 1; }

# Install Ansible Galaxy requirements
echo "Installing Ansible Galaxy dependencies..."
kolla-ansible install-deps || { echo "Ansible Galaxy dependencies installation failed"; exit 1; }

# Generate passwords
echo "Generating passwords..."
kolla-genpwd || { echo "Password generation failed"; exit 1; }

# Process Neutron interfaces and create corresponding bridge and physnet names
BRIDGE_NAMES=()
PHYSNET_NAMES=()

IFS=',' read -ra ADDR <<< "$EXT_INTERFACE"
for i in "${ADDR[@]}"; do
  BRIDGE="br-${i//./-}"
  PHYSNET="physnet${i//./-}"
  BRIDGE_NAMES+=("$BRIDGE")
  PHYSNET_NAMES+=("$PHYSNET")
done

# If Octavia is enabled, add the LB interface to the lists
if [ "$OCTAVIA_ENABLED" == "yes" ]; then
  EXT_INTERFACE="${EXT_INTERFACE},${OCTAVIA_LB_INTERFACE}"
  LB_BRIDGE="br-${OCTAVIA_LB_INTERFACE//./-}"
  LB_PHYSNET="physnet${OCTAVIA_LB_INTERFACE//./-}"
  
  BRIDGE_NAMES+=("$LB_BRIDGE")
  PHYSNET_NAMES+=("$LB_PHYSNET")
fi

PHYSNETS=$(IFS=,; echo "${PHYSNET_NAMES[*]}")
BRIDGES=$(IFS=,; echo "${BRIDGE_NAMES[*]}")

# Create OVN mappings by pairing physical networks with bridges
OVN_MAPPINGS=$(paste -d: <(echo "$PHYSNETS" | tr ',' '\n') <(echo "$BRIDGES" | tr ',' '\n') | paste -sd, -)


# Create a new minimal globals.yml
echo "Creating a new minimal globals.yml..."
cat <<EOL > /etc/kolla/globals.yml
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
nova_compute_virt_type: "kvm"
kolla_internal_vip_address: "$KOLLA_INTERNAL_VIP"
network_interface: "$MGMT_INTERFACE"
neutron_external_interface: "$EXT_INTERFACE"
tunnel_interface: "$TUNNEL_INTERFACE"
neutron_bridge_name: "$BRIDGES"
neutron_physical_network: "$PHYSNETS"
ovn_mappings: "$OVN_MAPPINGS"
neutron_plugin_agent: "ovn"
neutron_tenant_network_types: "vxlan,vlan,flat"
enable_neutron_provider_networks: "yes"
neutron_ovn_distributed_fip: "yes"
EOL

# Add custom Horizon theme settings if applicable
if [ "$USE_CUSTOM_THEME" == "yes" ]; then
  echo "horizon_custom_themes:" >> /etc/kolla/globals.yml
  echo "  - name: adani" >> /etc/kolla/globals.yml
  echo "    label: adani" >> /etc/kolla/globals.yml
fi

# Enable HAProxy and OpenStack core services by default
echo "enable_haproxy: \"yes\"" >> /etc/kolla/globals.yml
echo "enable_openstack_core: \"yes\"" >> /etc/kolla/globals.yml
echo "nova_console: \"novnc\"" >> /etc/kolla/globals.yml
echo "enable_mariadb_clustercheck: \"yes\"" >> /etc/kolla/globals.yml
echo "enable_keepalived: \"yes\"" >> /etc/kolla/globals.yml

# Enable additional services
for ENABLE in "${ENABLE_LIST[@]}"; do
  case $ENABLE in
    1)
      echo "enable_barbican: \"yes\"" >> /etc/kolla/globals.yml
      ;;
    2)
      echo "enable_octavia: \"yes\"" >> /etc/kolla/globals.yml
      echo "octavia_auto_configure: \"yes\"" >> /etc/kolla/globals.yml
      echo "enable_redis: \"yes\"" >> /etc/kolla/globals.yml
      echo "octavia_amp_network:" >> /etc/kolla/globals.yml
      echo "  name: \"lb-mgmt-net\"" >> /etc/kolla/globals.yml
      echo "  provider_network_type: \"flat\"" >> /etc/kolla/globals.yml
      echo "  provider_physical_network: \"$LB_PHYSNET\"" >> /etc/kolla/globals.yml
      echo "  external: false" >> /etc/kolla/globals.yml
      echo "  shared: false" >> /etc/kolla/globals.yml
      echo "  mtu: 8950" >> /etc/kolla/globals.yml
      echo "  subnet:" >> /etc/kolla/globals.yml
      echo "    name: \"lb-mgmt-subnet\"" >> /etc/kolla/globals.yml
      echo "    cidr: \"$OCTAVIA_CIDR\"" >> /etc/kolla/globals.yml
      echo "    allocation_pool_start: \"$OCTAVIA_POOL_START\"" >> /etc/kolla/globals.yml
      echo "    allocation_pool_end: \"$OCTAVIA_POOL_END\"" >> /etc/kolla/globals.yml
      echo "    gateway_ip: \"$OCTAVIA_GATEWAY_IP\"" >> /etc/kolla/globals.yml
      echo "    enable_dhcp: \"yes\"" >> /etc/kolla/globals.yml
      echo "octavia_certs_country: IN" >> /etc/kolla/globals.yml
      echo "octavia_certs_state: Delhi" >> /etc/kolla/globals.yml
      echo "octavia_certs_organization: coredge" >> /etc/kolla/globals.yml
      echo "octavia_certs_organizational_unit: Openstack" >> /etc/kolla/globals.yml
      ;;
    *)
      echo "Invalid selection: $ENABLE"
      ;;
  esac
done


# Enable SAN storage in Cinder if selected
if [ "$STORAGE_CHOICE" == "2" ]; then
  echo "enable_cinder: \"yes\"" >> /etc/kolla/globals.yml
  echo "#enable_cinder_backend_huawei: \"yes\"" >> /etc/kolla/globals.yml
  echo "skip_cinder_backend_check: \"true\"" >> /etc/kolla/globals.yml

  # Create Cinder Huawei configuration file
  sudo mkdir -p /etc/kolla/config/cinder/cinder-volume
  cat <<EOL > /etc/kolla/config/cinder/cinder-volume/cinder_huawei_conf.xml
<?xml version="1.0" encoding="UTF-8"?>
<config>
    <Storage>
        <Product>$SAN_PRODUCT</Product>
        <Protocol>$SAN_PROTOCOL</Protocol>
        <UserName>$SAN_USERNAME</UserName>
        <UserPassword>$SAN_PASSWORD</UserPassword>
        <RestURL>$SAN_REST_URL</RestURL>
    </Storage>
    <LUN>
        <LUNType>Thin</LUNType>
        <WriteType>1</WriteType>
        <Prefetch Type="None" Value="0" />
        <StoragePool>Blazepool</StoragePool>
    </LUN>
    <Host>
        <OSType>Linux</OSType>
        <HostIP>$SAN_HOST_IPS</HostIP>
    </Host>
</config>
EOL

  # Create Cinder configuration file
  cat <<EOL > /etc/kolla/config/cinder.conf
[DEFAULT]
enabled_backends = huawei_fc

[huawei_fc]
volume_driver = cinder.volume.drivers.huawei.huawei_driver.HuaweiFCDriver
volume_backend_name = Huawei_Storage
cinder_huawei_conf_file = /etc/kolla/config/cinder/cinder-volume/cinder_huawei_conf.xml
EOL
fi

# Update the multinode inventory file
echo "Updating multinode inventory file..."

# Remove specific entries
sed -i '/control01/d' multinode
sed -i '/control02/d' multinode
sed -i '/control03/d' multinode
sed -i '/network01/d' multinode
sed -i '/network02/d' multinode
sed -i '/compute01/d' multinode
sed -i '/monitoring01/d' multinode
sed -i '/storage01/d' multinode

# Remove the old blocks
sed -i '/^\[control\]/,/^\[/d' multinode
sed -i '/^\[network\]/,/^\[/d' multinode
sed -i '/^\[compute\]/,/^\[/d' multinode
sed -i '/^\[monitoring\]/,/^\[/d' multinode
sed -i '/^\[storage\]/,/^\[/d' multinode

# Function to add a block with new hostnames at the top of the file
add_block_with_hostnames() {
    local block_name=$1
    local ips=$2

    echo "[$block_name]" > /tmp/temp_multinode

    for ip in ${ips//,/ }; do
        hostname=$(grep -w "$ip" /etc/hosts | awk '{print $2}')
        if [ -n "$hostname" ]; then
            echo "$hostname" >> /tmp/temp_multinode
        fi
    done

    # Add the block to the top of the multinode file
    sed -i "1e cat /tmp/temp_multinode" multinode
    rm /tmp/temp_multinode
}

# Add new blocks with hostnames at the top of the file
add_block_with_hostnames "control" "$CONTROLLER_IPS"
add_block_with_hostnames "network" "$CONTROLLER_IPS"
add_block_with_hostnames "compute" "$COMPUTE_IPS"
add_block_with_hostnames "monitoring" "$CONTROLLER_IPS"
add_block_with_hostnames "storage" "$CONTROLLER_IPS"

# Ensure [deployment] block is present and correctly placed
if ! grep -q '^\[deployment\]' multinode; then
    echo -e "[deployment]\nlocalhost ansible_connection=local" >> multinode
fi

# Comment out the first occurrence of "localhost ansible_connection=local"
sed -i '0,/localhost *ansible_connection=local/s//\#&/' multinode

echo "Multinode inventory file updated successfully."

# Run Octavia certificate generation command
echo "Generating Octavia certificates..."
kolla-ansible octavia-certificates || { echo "Octavia certificate generation failed"; exit 1; }

# Prompt for using config overrides
if [ "$USE_CONFIG_OVERRIDES" == "yes" ]; then
  if [ -d "/root/config" ]; then
    sudo mkdir -p /etc/kolla/config
    sudo cp -r /root/config/* /etc/kolla/config/
    echo "Config overrides copied to /etc/kolla/config/"
  else
    echo "Directory /root/config not found. Exiting."
    exit 1
  fi
fi

# Run Kolla Ansible pre-check
echo "Running Kolla Ansible pre-check..."
kolla-ansible -i multinode bootstrap-servers -vv || { echo "Bootstrap servers failed"; exit 1; }
kolla-ansible -i multinode prechecks -vv || { echo "Pre-checks failed"; exit 1; }

# Deploy OpenStack
echo "Deploying OpenStack..."
kolla-ansible -i multinode deploy -vv || { echo "OpenStack deployment failed"; exit 1; }

# Post-deployment tasks
echo "Setting up Horizon dashboard..."
kolla-ansible -i multinode post-deploy -vv || { echo "Post-deploy tasks failed"; exit 1; }

# Run the Ansible playbook to set up the timezone and Chrony using the multinode inventory
ansible-playbook -i multinode setup_timezoneA.yml --extra-vars "ntp_servers=$NTP_SERVERS" || { echo "Ansible playbook failed"; exit 1; }

# Deployment summary
echo "OpenStack deployment is complete."
echo "You can access the Horizon dashboard at http://$KOLLA_INTERNAL_VIP/"

