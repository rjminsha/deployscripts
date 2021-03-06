#!/bin/bash
 
#********************************************************************************
# Copyright 2014 IBM
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#********************************************************************************
terrible mistake 


dump_info () {
    echo -e "${label_color}Container Information: ${no_color}"
    echo -e "${label_color}Information about this organization and space${no_color}:"
    echo "Summary:"
    local ICEINFO=$(ice info 2>/dev/null)
    echo "$ICEINFO"

 
    export CONTAINER_LIMIT=$(echo "$ICEINFO" | grep "Containers limit" | awk '{print $4}')
    export IP_LIMIT=$(echo "$ICEINFO" | grep "Floating IPs limit" | awk '{print $5}')
    export CONTAINER_COUNT=$(echo "$ICEINFO" | grep "Containers usage" | awk '{print $4}')
    export IP_COUNT=$(echo "$ICEINFO" | grep "Floating IPs usage" | awk '{print $5}')
    local WARNING_LEVEL="$(echo "$CONTAINER_LIMIT - 2" | bc)"

    if [ ${CONTAINER_COUNT} -ge ${CONTAINER_LIMIT} ]; then 
        echo -e "${red}You have ${CONTAINER_COUNT} containers running, and may reached the default limit on the number of containers ${no_color}"
    elif [ ${CONTAINER_COUNT} -ge ${WARNING_LEVEL} ]; then
        echo -e "${label_color}There are ${CONTAINER_COUNT} containers running, which is approaching the limit of ${CONTAINER_LIMIT}${no_color}"
    fi 
 
    local AVAILABLE="$(echo "$IP_LIMIT - $IP_COUNT" | bc)"
    if [ ${AVAILABLE} -le 0 ]; then 
        echo -e "${red}You have reached the default limit for the number of available public IP addresses${no_color}"
    else
        echo -e "${label_color}You have ${AVAILABLE} public IP addresses remaining${no_color}"
    fi  

    echo "Groups: "
    ice group list 2> /dev/null 
    echo "Routes: "
    cf routes 
    echo "Running Containers: "
    ice ps 2> /dev/null 
    echo "All floating IP addresses"
    ice ip list --all 2> /dev/null 
    return 0
}

update_inventory(){
    local TYPE=$1
    local NAME=$2 
    local ACTION=$3
    if [ $# -ne 3 ]; then 
        echo -e "${red}updating inventory expects a three inputs: 1. type 2. name 3. action. Where type is either group or container, and the name is the name of the container being added to the inventory.${no_color}"
        return 1
    fi  
    local ID="undefined"
    # find the container or group id 
    if [ "$TYPE" == "ibm_containers" ]; then 
        ID=$(ice inspect ${NAME} 2> /dev/null | grep "\"Id\":" | awk '{print $2}')
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Could not find container called $NAME${no_color}"
            ice ps 2> /dev/null 
            return 1 
        fi 

    elif [ "${TYPE}" == "ibm_containers_group" ]; then
        ID=$(ice group inspect ${NAME} 2> /dev/null | grep "\"Id\":" | awk '{print $2}')
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Could not find group called $NAME${no_color}"
            ice group list 2> /dev/null 
            return 1 
        fi 
    else 
        echo -e "${red}Could not update inventory with unknown type: ${TYPE}${no_color}"
        return 1
    fi 

    local JOB_TYPE=""
    # trim off junk 
    local temp="${ID%\",}"
    ID="${temp#\"}"
    echo "The ID of the $TYPE is: $ID"
 
    # find other inventory information 
    echo -e "${label_color}Updating inventory with $TYPE of $NAME ${no_color}"
    IDS_INV_URL="${IDS_URL%/}"
    IDS_REQUEST=$TASK_ID
    IDS_DEPLOYER=${JOB_NAME##*/}
    if [ ! -z "$COPYARTIFACT_BUILD_NUMBER" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$COPYARTIFACT_BUILD_NUMBER
    elif [ ! -z "$CS_BUILD_SELECTOR" ] ; then
        IDS_VERSION_TYPE="JENKINS_BUILD_ID"
        IDS_VERSION=$CS_BUILD_SELECTOR
    else
            IDS_VERSION_TYPE="SCM_REV_ID"
        if [ ! -z "$GIT_COMMIT" ] ; then
            IDS_VERSION=$GIT_COMMIT
        elif [ ! -z "$RTCBuildResultUUID" ] ; then
            IDS_VERSION=$RTCBuildResultUUID
        fi
    fi

    if [ -z "$IDS_RESOURCE" ]; then 
        local IDS_RESOURCE="https://hub.jazz.net/pipeline"
    fi 

    if [ -z "$IDS_VERSION" ]; then 
        local IDS_RESOURCE="1"
    fi 

    IDS_RESOURCE=$CF_SPACE_ID
    if [ -z "$IDS_RESOURCE" ]; then 
        echo -e "${red}Could not find CF SPACE in environment, using production space id${no_color}"
    else 
        # call IBM DevOps Service Inventory CLI to update the entry for this deployment
        echo "bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION"
        bash ids-inv -a ${ACTION} -d $IDS_DEPLOYER -q $IDS_REQUEST -r $IDS_RESOURCE -s $ID -t ${TYPE} -u $IDS_INV_URL -v $IDS_VERSION
    fi 
}
 
insert_inventory(){
    update_inventory $1 $2 "insert"
}
delete_inventory(){
    update_inventory $1 $2 "delete"
}
 
# function to wait for a container to start 
# takes a container name as the only parameter
wait_for (){
    local WAITING_FOR=$1 
    if [ -z ${WAITING_FOR} ]; then 
        echo "${red}Expected container name to be passed into wait_for${no_color}"
        return 1
    fi 
    local COUNTER=0
    local STATE="unknown"
    while [[ ( $COUNTER -lt 60 ) && ("${STATE}" != "Running") ]]; do
        let COUNTER=COUNTER+1 
        STATE=$(ice inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then 
            STATE="being placed"
        fi 
        echo "${WAITING_FOR} is ${STATE}"
        sleep 2
    done
    if [ "$STATE" != "Running" ]; then
        echo -e "${red}Failed to start instance ${no_color}"
        return 1
    fi  
    return 0 
}

# function to wait for a container to start 
# takes a container name as the only parameter
wait_for_stopped (){
    local WAITING_FOR=$1 
    if [ -z ${WAITING_FOR} ]; then 
        echo "${red}Expected container name to be passed into wait_for${no_color}"
        return 1
    fi 
    local COUNTER=0
    local FOUND=0
    while [[ ( $COUNTER -lt 60 ) && ("${STATE}" != "Shutdown")  ]]; do
        let COUNTER=COUNTER+1 
        STATE=$(ice inspect $WAITING_FOR 2> /dev/null | grep "Status" | awk '{print $2}' | sed 's/"//g')
        if [ -z "${STATE}" ]; then 
            STATE="being deleted"
        fi 
        sleep 2
    done
    if [ "$STATE" != "Shutdown" ]; then
        echo -e "${red}Failed to stop instance $WAITING_FOR ${no_color}"
        return 1
    else
        echo -e "Successfully stopped $WAITING_FOR"
    fi 
    return 0 
}
 
deploy_container() {
    local MY_CONTAINER_NAME=$1 
    echo "deploying container ${MY_CONTAINER_NAME}"
 
    if [ -z MY_CONTAINER_NAME ];then 
        echo "${red}No container name was provided${no_color}"
        return 1 
    fi 
 
    # check to see if that container name is already in use 
    ice inspect ${MY_CONTAINER_NAME} > /dev/null
    local FOUND=$?
    if [ ${FOUND} -eq 0 ]; then 
        echo -e "${red}${MY_CONTAINER_NAME} already exists.  Please remove these containers or change the Name of the container or group being deployed${no_color}"
    fi  
 
    # run the container and check the results
    ice run --name "${MY_CONTAINER_NAME}" --publish "${PORT}" ${IMAGE_NAME} 2> /dev/null
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo -e "${red}Failed to deploy ${MY_CONTAINER_NAME} using ${IMAGE_NAME}${no_color}"
        dump_info
        return 1
    fi 
 
    # wait for container to start 
    wait_for ${MY_CONTAINER_NAME}
    RESULT=$?
    if [ $RESULT -eq 0 ]; then 
        insert_inventory "ibm_containers" ${MY_CONTAINER_NAME}
    fi 
    return ${RESULT}
}
 
deploy_simple () {
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        echo -e "${red}Error encountered with simple build strategy for ${CONTAINER_NAME}_${BUILD_NUMBER}${no_color}"
        exit $RESULT
    fi
}
 
deploy_red_black () {
    echo -e "${label_color}Example red_black container deploy ${no_color}"
    # deploy new version of the application 
    local MY_CONTAINER_NAME="${CONTAINER_NAME}_${BUILD_NUMBER}"
    local FLOATING_IP=""
    deploy_container ${MY_CONTAINER_NAME}
    local RESULT=$?
    if [ $RESULT -ne 0 ]; then
        exit $RESULT
    fi

    echo "Cleaning up previous deployments.  Will keep ${CONCURRENT_VERSIONS} versions active."

    if [ -z "$REMOVE_FROM" ]; then 
        COUNTER=${BUILD_NUMBER}
    else 
        COUNTER=$REMOVE_FROM
    fi 
    local FOUND=0
    until [  $COUNTER -lt 1 ]; do
        ice inspect ${CONTAINER_NAME}_${COUNTER} > inspect.log 2> /dev/null
        RESULT=$?
        if [ $RESULT -eq 0 ]; then
            echo "Found container ${CONTAINER_NAME}_${COUNTER}"
            # does it have a public IP address 
            let FOUND+=1
            
            if [ -z "${FLOATING_IP}" ]; then 
                FLOATING_IP=$(cat inspect.log | grep "PublicIpAddress" | awk '{print $2}')
                temp="${FLOATING_IP%\"}"
                FLOATING_IP="${temp#\"}"
                echo "Discovered previous IP ${FLOATING_IP}"
            else
                echo "Did not discovered previous IP because we already have discovered $FLOATING_IP"
            fi

            if [ $FOUND -le $CONCURRENT_VERSIONS ]; then
                # this is the first previous deployment I have found
                if [ -z "${FLOATING_IP}" ]; then 
                    echo "${CONTAINER_NAME}_${COUNTER} did not have a floating IP so will need to discover one from previous deployment or allocate one"
                else 
                    echo "${CONTAINER_NAME}_${COUNTER} had a floating ip ${FLOATING_IP}"
                    ice ip unbind ${FLOATING_IP} ${CONTAINER_NAME}_${COUNTER} 2> /dev/null
                    sleep 2
                    ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
                    echo "keeping previous deployment: ${CONTAINER_NAME}_${COUNTER}"
                fi 
            else 
                echo "removing previous deployment: ${CONTAINER_NAME}_${COUNTER}" 
                ice stop ${CONTAINER_NAME}_${COUNTER} 
                wait_for_stopped ${CONTAINER_NAME}_${COUNTER} 
                ice rm ${CONTAINER_NAME}_${COUNTER} 2> /dev/null
                delete_inventory "ibm_containers" ${CONTAINER_NAME}_${COUNTER}
            fi  
        fi 
        let COUNTER-=1
    done
    # check to see that I obtained a floating IP address
    #ice inspect ${CONTAINER_NAME}_${BUILD_NUMBER} > inspect.log 
    #FLOATING_IP=$(cat inspect.log | grep "PublicIpAddress" | awk '{print $2}')
    if [ "${FLOATING_IP}" = '""' ] || [ -z "${FLOATING_IP}" ]; then 
        echo "Requesting IP"
        FLOATING_IP=$(ice ip request 2> /dev/null | awk '{print $4}' | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -e "${label_color}Failed to request new IP address, will attempt to reuse existing IP${no_color}" 
            FLOATING_IP=$(ice ip list 2> /dev/null | grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -n 1)
            #strip off whitespace 
            FLOATING_IP=${FLOATING_IP// /}
            if [ -z "${FLOATING_IP}" ];then 
                echo -e "${red}Could not request a new, or reuse existing IP address ${no_color}"
                dump_info
                exit 1 
            else 
                echo "Assigning existing IP address $FLOATING_IP"
            fi 
        else 
            # strip off junk 
            temp="${FLOATING_IP%\"}"
            FLOATING_IP="${temp#\"}"
            echo "Assigning new IP address $FLOATING_IP"
        fi 
        ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -e "${red}Failed to bind ${FLOATING_IP} to ${CONTAINER_NAME}_${BUILD_NUMBER} ${no_color}" 
            echo "Unsetting TEST_URL"
            export TEST_URL=""
            dump_info
            exit 1 
        fi 
    else 
        ice ip bind ${FLOATING_IP} ${CONTAINER_NAME}_${BUILD_NUMBER} 2> /dev/null
    fi 
    echo "Exporting TEST_URL:${TEST_URL}"
    export TEST_URL="${URL_PROTOCOL}${FLOATING_IP}:${PORT}"
    echo -e "${green}Public IP address of ${CONTAINER_NAME}_${BUILD_NUMBER} is ${FLOATING_IP} and the TEST_URL is ${TEST_URL} ${no_color}"
}
    
##################
# Initialization #
##################
# Check to see what deployment type: 
#   simple: simply deploy a container and set the inventory 
#   red_black: deploy new container, assign floating IP address, keep original container 
if [ -z "$URL_PROTOCOL" ]; then 
 export URL_PROTOCOL="http://" 
fi 
if [ -z "$PORT" ]; then 
 export PORT='80' 
fi 
if [ -z "$CONCURRENT_VERSIONS" ];then 
    export CONCURRENT_VERSIONS=1
fi 
 
 
echo "Deploying using ${DEPLOY_TYPE} strategy, for ${CONTAINER_NAME}, deploy number ${BUILD_NUMBER}"
if [ "${DEPLOY_TYPE}" == "red_black" ]; then 
    deploy_red_black
else 
    echo -e "${label_color}Currently only supporting red_black deployment strategy${no_color}"
    echo -e "${label_color}If you would like another strategy please fork https://github.com/Osthanes/deployscripts.git and submit a pull request${no_color}"
    echo -e "${label_color}Defaulting to red_black deploy${no_color}"
    deploy_red_black
fi 
dump_info
exit 0
