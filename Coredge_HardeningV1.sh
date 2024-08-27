#!/bin/bash
#run by ./hardening.sh ip1 ip2 ....
set -e  # Exit on any error

# Step 1: Install Ansible and Git
install_ansible() {
    echo "Installing Ansible and Git..."
    sudo apt update
    sudo apt install ansible git -y
}

# Step 2: Clone the ansible-hardening role from GitHub
clone_hardening_role() {
    if [ -d "$HOME/.ansible/roles/ansible-hardening" ]; then
        echo "The ansible-hardening role already exists. Skipping clone."
    else
        echo "Cloning ansible-hardening role..."
        mkdir -p ~/.ansible/roles/
        git clone https://github.com/openstack/ansible-hardening ~/.ansible/roles/ansible-hardening
    fi
}

# Step 3: Create an inventory file
create_inventory() {
    echo "Creating inventory file..."
    echo "[ubuntu_servers]" > hosts
    for ip in "$@"; do
        echo "$ip ansible_user=root" >> hosts
    done
}

# Step 4: Create a playbook with custom variables
create_playbook() {
    echo "Creating playbook..."
    cat <<EOL > hardening.yml
---
- name: Harden all systems
  hosts: ubuntu_servers
  become: yes
  vars:
    security_sshd_permit_root_login: yes
    security_enable_firewalld: no
    security_rhel7_initialize_aide: no
    security_ntp_servers:
      - 0.ubuntu.pool.ntp.org
      - 1.ubuntu.pool.ntp.org
  roles:
    - ansible-hardening
EOL
}

# Step 5: Run the playbook in check mode
run_check_mode() {
    echo "Running playbook in check mode..."
    ansible-playbook -i hosts hardening.yml --check | tee check_output.log

    if grep -q "failed=[^0]" check_output.log; then
        echo "Check mode detected failures. Exiting..."
        exit 1
    fi
}

# Step 6: Apply the hardening
apply_hardening() {
    echo "Applying hardening..."
    ansible-playbook -i hosts hardening.yml --diff | tee apply_output.log

    # Extract and log changed tasks
    grep -E 'TASK \[|changed=' apply_output.log > task_changes.log
}

# Main Execution Flow
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <IP1> [IP2] [IP3] ..."
    exit 1
fi

install_ansible
clone_hardening_role
create_inventory "$@"
create_playbook
run_check_mode
apply_hardening

echo "Hardening completed successfully. Check 'task_changes.log' for details."


