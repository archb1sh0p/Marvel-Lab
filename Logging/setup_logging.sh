#!/bin/bash
#Authors: Jonathan Johnson & Ben Shell
#References: https://stackoverflow.com/ && https://github.com/target/huntlib.git

SETUP_SPLUNK="True"
SETUP_ELASTIC="False"
SETUP_ZEEK="False"

HOST_IP="<logger-IP>"

# Checking to see if script is running as root
if [[ $EUID -ne 0 ]]; then
	echo -e "\x1B[01;31m[X] Script Must Be Run As ROOT\x1B[0m"
	exit 1
	fi

echo -e "\x1B[01;34m[*] Setting timezone to UTC...\x1B[0m"
timedatectl set-timezone UTC

# Checking Docker
echo -e "\x1B[01;34m[*] Checking to see if Docker is installed...\x1B[0m"

if [[ $(which docker) && $(docker compose version) ]]; then
    echo -e "\x1B[01;32m[*] Docker Compose is installed\x1B[0m"
  else
	echo -e "\x1B[01;31m[*] Docker was not found. See the Read the Docs installation documentation (https://marvel-lab.readthedocs.io/en/latest/subpages/build_steps.html#logging) \x1B[0m"
	exit 0
  fi

# Enabling docker service:
echo -e "\x1B[01;34m[*] Checking for the Docker service...\x1B[0m"
if [[ $(systemctl list-unit-files --state=enabled | grep docker.service) ]]; then
	echo -e "\x1B[01;32m[*] Docker service already enabled\x1B[0m"
	else
		systemctl enable docker.service
	fi

# Starting containers
echo -e "\x1B[01;34m[*] Starting containers\x1B[0m"
docker compose up -d

# Zeek
if [ "$SETUP_ZEEK" = "True" ]; then
	export $(grep -v '^#' Config/zeek/.env | xargs)
	echo -e "Zeek needs a network interface to monitor. The currently configured interface is '${INTERFACE}'."
	read -r -p "Would you like to change the selected interface? You'll need to set the interface if this is the first time running this script. Otherwise you can set it in Config/zeek/.env [y/N] " response1
	
	if [[ "$response1" =~ ^([yY][eE][sS]|[yY])$ ]]; then
		
		read -r -p "Would you like to print out your interfaces to see which one to monitor? [y/N] " response2
		
		if [[ "$response2" =~ ^([yY][eE][sS]|[yY])$ ]]; then
			if hash ifconfig 2>/dev/null; then
				ifconfig
			else
				ip address
			fi
		else
			echo -e "\x1B[01;34m[*] Moving on...\x1B[0m"
		fi

		read -p 'Input the network interface you would like Zeek to monitor and press [ENTER]: ' INTERFACE

		echo -e "\x1B[01;34m[*] Writing desired interface to Config/zeek/.env\x1B[0m"
		echo "INTERFACE=${INTERFACE}" > ./Config/zeek/.env
	fi

	echo -e "\x1B[01;34m[*] Creating Zeek:\x1B[0m"
	docker compose -f ./Config/zeek/zeek-compose.yml up -d
	fi

# Elastic
if [ "$SETUP_ELASTIC" = "True" ]; then
	export $(grep -v '^#' Config/elasticstack/.env | xargs)

	if [ "$ELASTIC_PASSWORD" = '' ]; then
		echo -e "\x1B[01;34m[*] Elastic and Kibana need a password. You can enter it here, or close this script and configure in Config/elasticstack/.env\x1B[0m"
		read -p 'Enter your desired password: ' NEW_ELASTIC_PASSWORD
		sed -i "s/ELASTIC_PASSWORD=/ELASTIC_PASSWORD=$NEW_ELASTIC_PASSWORD/" Config/elasticstack/.env
		sed -i "s/KIBANA_PASSWORD=/KIBANA_PASSWORD=$NEW_ELASTIC_PASSWORD/" Config/elasticstack/.env
		fi

	echo -e "\x1B[01;34m[*] Checking vm.max_map_count\x1B[0m"
	if [[ "$(sysctl vm.max_map_count)" != "vm.max_map_count = 262144" ]]; then
		echo -e "\x1B[01;34m[*] Updating vm.max_map_count in /etc/sysctl.conf\x1B[0m"
		echo "vm.max_map_count=262144" >> /etc/sysctl.conf
		sysctl -p
		fi

	echo -e "\x1B[01;34m[*] Creating Elastic Stack:\x1B[0m"
	docker compose -f ./Config/elasticstack/elasticstack-compose.yml up -d
	fi

# Splunk
if [ "$SETUP_SPLUNK" = "True" ]; then
	# Define healthcheck function for splunk
	splunk_healthcheck(){
		echo -e "\x1B[01;32m[*] Waiting for splunk...\x1B[0m"
		SPLUNK_STATUS=""
		while [[ "$SPLUNK_STATUS" != "\"healthy"\" ]]
		do
			sleep 3
			SPLUNK_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' splunk)
		done
	}

	export $(grep -v '^#' Config/splunk/.env | xargs)

	if [ "$SPLUNK_PASSWORD" = '' ]; then
		echo -e "\x1B[01;34m[*] Splunk needs a password. You can enter it here, or close this script and configure in Config/splunk/.env\x1B[0m"
		read -p 'Enter your desired password: ' NEW_SPLUNK_PASSWORD
		sed -i "s/SPLUNK_PASSWORD=/SPLUNK_PASSWORD=$NEW_SPLUNK_PASSWORD/" Config/splunk/.env
		fi
		

	# Start Splunk
	docker compose -f ./Config/splunk/splunk-compose.yml up -d

	# Wait for splunk to finish installing
	splunk_healthcheck

	# The 'docker cp' commands are needed after Splunk install, otherwise our custom config would be overwritten
	docker cp Config/splunk/inputs.conf splunk:/opt/splunk/etc/system/local/inputs.conf
	docker cp Config/splunk/indexes.conf splunk:/opt/splunk/etc/system/local/indexes.conf
	echo -e "\x1B[01;32m[*] Restarting splunk to apply inputs.conf and indexes.conf\x1B[0m"
	docker restart splunk
	splunk_healthcheck

	# Checking Jupyter Notebooks
	echo -e "\x1B[01;34m[*] Checking Jupyter Notebooks...\x1B[0m"
	sleep 10
	token="$(docker logs jupyter-notebooks 2>&1 | grep "ServerApp]  or http" | cut -d "?" -f 2)"

	echo -e "\x1B[01;32m[*] Access Splunk at http://$HOST_IP:8000 with the username 'admin'\x1B[0m"
	echo -e "\x1B[01;32m[*] Access Jupyter Notebook at: http://$HOST_IP:8888/lab?$token \x1B[0m"
	fi

# Print out info
echo -e "\x1B[01;32m[*] Access Portainer at https://$HOST_IP/portainer/ \x1B[0m"
