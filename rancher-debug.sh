#!/bin/bash
bold=$(tput bold)
normal=$(tput sgr0)
RED='\e[0;31m'
GREEN='\e[0;32m'
NC='\e[0m'

#################### Rancher Server #########################
#################### NFS Server #########################

read -p "Do you want to install NFS server? (y/n): " install_nfs
if [[ $install_nfs == "y" || $install_nfs == "Y" ]]; then
    read -p "Enter path NFS (ex. /data): " nfsdir
    read -p "Enter network NFS (ex. 192.168.0.0): " network_nfs
fi

read -p "Enter Rancher version (ex. v2.xx.xx): " version


#############################################################
#################### NFS Server #############################

communitystring=olsmonitor

#############################################################
####################### update ##############################
#############################################################

echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "${RED}########################################################################################${NC}"
echo ""
echo -e "Preparing ${bold}${RED}Rancher Server${NC}${normal}"
echo ""
echo "1.Update "
Update()
{
        apt update -y
        apt upgrade -y
        apt install sshpass -y
}
echo "[DEBUG] Running Update..."
Update
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 1 (Update) FAILED${NC}"; exit 1; fi
echo "Update success"

############################################################
#################### install docker ########################
############################################################

echo "2.Install docker"
if [[ $(which docker) && $(docker --version) ]]; then
        echo -e "Docker already ${RED}installed${NC}"
else
        echo "[DEBUG] Downloading and running docker install script..."
        curl -s https://get.docker.com | sh
        if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 2 (Docker install) FAILED${NC}"; exit 1; fi
        echo "Install docker success"
fi
echo "[DEBUG] Writing /etc/docker/daemon.json..."
mirror='{
"registry-mirrors": ["https://ols-dockerhubcache.dedyn.io"]
}'
sudo cat <<EOF > /etc/docker/daemon.json
$mirror
EOF
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 2 (daemon.json write) FAILED${NC}"; exit 1; fi

###############################################################
####################### install chrony ########################
###############################################################

echo "3.Install chrony"
Chrony()
{
        timedatectl set-timezone Asia/Bangkok
        apt install chrony -y
        sed -i 's/pool/#pool/g'  /etc/chrony/chrony.conf
        sed -i 's/#pool 2.ubuntu.#pool.ntp.org iburst maxsources 2/server clock.inet.co.th/g'  /etc/chrony/chrony.conf
        systemctl restart chrony
}
echo "[DEBUG] Running Chrony..."
Chrony
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 3 (Chrony) FAILED${NC}"; exit 1; fi
echo "Install chrony success"

###############################################################
###################### Node exporter ##########################
###############################################################

echo "4.Install Node exporter"
Nodeexporter()
{
        useradd -M -r -s /bin/false node_exporter
        wget https://github.com/prometheus/node_exporter/releases/download/v1.0.1/node_exporter-1.0.1.linux-amd64.tar.gz
        tar xzf node_exporter-1.0.1.linux-amd64.tar.gz
        cp node_exporter-1.0.1.linux-amd64/node_exporter /usr/local/bin/
        chown node_exporter:node_exporter /usr/local/bin/node_exporter
        cat <<EOF > /etc/systemd/system/node_exporter.service
        [Unit]
        Description=Prometheus Node Exporter
        Wants=network-online.target
        After=network-online.target
        [Service]
        User=node_exporter
        Group=node_exporter
        Type=simple
        ExecStart=/usr/local/bin/node_exporter
        [Install]
        WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl start node_exporter.service
        systemctl enable node_exporter.service
}
echo "[DEBUG] Running Nodeexporter..."
Nodeexporter
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 4 (Node Exporter) FAILED${NC}"; exit 1; fi
echo "Install Node exporter success"

###############################################################
######################### Swapoff #############################
###############################################################

echo "5.Swapoff"
Swapoff(){
        swapoff -a
        sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
}
echo "[DEBUG] Running Swapoff..."
Swapoff
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 5 (Swapoff) FAILED${NC}"; exit 1; fi
echo "Swapoff success"

###############################################################
######################### SNMP #############################
###############################################################

echo "6.SNMP"
SNMP(){
        apt install snmp snmpd -y
        echo "rocommunity  $communitystring " >> /etc/snmp/snmpd.conf
        sudo sed  -i 's|127.0.0.1|udp:161|g' /etc/snmp/snmpd.conf
        systemctl restart snmpd
}
echo "[DEBUG] Running SNMP..."
SNMP
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 6 (SNMP) FAILED${NC}"; exit 1; fi
echo "SNMP success"

echo "7.KUBECTL"
KUBECTL(){
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
chmod +x kubectl
mkdir -p ~/.local/bin
mv ./kubectl ~/.local/bin/kubectl
mkdir -p ~/.kube
git clone https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner.git
}

echo "[DEBUG] Running KUBECTL..."
KUBECTL
if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 7 (KUBECTL) FAILED${NC}"; exit 1; fi
echo "KUBECTL success"

###############################################################
####################### Install Rancher  ######################
###############################################################

if [[ "$(docker container inspect -f '{{.State.Status}}' rancher )" == "running" || "$(docker container inspect -f '{{.State.Status}}' rancher )" == "exited" ]]> /dev/null 2>&1; then
        echo -e "7.Rancher container ${RED}have been created${NC}"
else
########################  No-CERT !!!!!
        echo "[DEBUG] Running docker run rancher..."
        docker run -d --restart=unless-stopped --name rancher -p 80:80 -p 443:443 --privileged rancher/rancher:$version
        if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 8 (Rancher docker run) FAILED${NC}"; exit 1; fi
########################  CERT !!!!!
#       docker run -d --restart=unless-stopped --name rancher \
#         -p 80:80 -p 443:443 \
#         --privileged \
#         -v /opt/rancher:/var/lib/rancher \
#         -v /var/log/rancher/auditlog:/var/log/auditlog \
#         -v /root/rancher/ssl/openlandscape.pem:/etc/rancher/ssl/cert.pem \
#         -v /root/rancher/ssl/openlandscape-private-key.pem:/etc/rancher/ssl/key.pem \
#         -v /etc/localtime:/etc/localtime:ro \
#         -e AUDIT_LEVEL=1 \
#         rancher/rancher:stable \
#         --no-cacerts

        echo "8.Install Rancher success"
fi
echo ""
echo -e "Prepare ${bold}${RED}Rancher Server${normal} ${GREEN}Complete"
echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "${RED}########################################################################################${NC}"
echo ""


##############################################################
#################### NFS Server     ##########################
##############################################################
NFSconfig(){
        apt install nfs-kernel-server -y
        systemctl enable nfs-server
        systemctl start nfs-server

        if [ -d "$nfsdir" ]; then
                echo "$nfsdir already exists"
        else
                mkdir -p $nfsdir
                echo "create"
        fi
        chown nobody:nogroup $nfsdir
        chmod -R 777 $nfsdir

        cat << EOF > /etc/exports
        # /etc/exports: the access control list for filesystems which may be exported
        #               to NFS clients.  See exports(5).
        #
        # Example for NFSv2 and NFSv3:
        # /srv/homes       hostname1(rw,sync,no_subtree_check) hostname2(ro,sync,no_subtree_check)
        #
        # Example for NFSv4:
        # /srv/nfs4        gss/krb5i(rw,sync,fsid=0,crossmnt,no_subtree_check)
        # /srv/nfs4/homes  gss/krb5i(rw,sync,no_subtree_check)
        $nfsdir         $network_nfs/24(rw,sync,no_subtree_check,insecure,no_root_squash,no_all_squash)
EOF
sudo exportfs -rav
sudo exportfs -v

}
if [[ $install_nfs == "y" || $install_nfs == "Y" ]]; then
    echo "[DEBUG] Running NFSconfig..."
    NFSconfig
    if [ $? -ne 0 ]; then echo -e "${RED}[DEBUG] STEP 9 (NFS Config) FAILED${NC}"; exit 1; fi
    echo "NFS Server setup completed."
else
    echo "Skipping NFS Server installation."
fi
#############################################################
echo "Bootstrap Password is here !!!!!!!"
sleep 40
docker logs  rancher  2>&1 | grep "Bootstrap Password:"
echo ""
echo -e ${GREEN}"Scrip prepare complete. Please join node on Rancher WEB UI"${NC}
echo ""
echo -e "${RED}########################################################################################${NC}"
echo -e "${RED}########################################################################################${NC}"
