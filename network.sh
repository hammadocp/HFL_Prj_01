#!/bin/bash
# Copyright IBM Corp All Rights Reserved
# SPDX-License-Identifier: Apache-2.0


ROOTDIR=$(cd "$(dirname "$0")" && pwd)
export PATH=${ROOTDIR}/bin:${PWD}/bin:$PATH
export FABRIC_CFG_PATH=${PWD}/config

# use this as the default docker-compose yaml definition
COMPOSE_FILE_BASE=docker-compose-Prj01-net.yaml


function createCryptoMaterials(){

  echo "Generating Crypto Material"

  cryptogen generate --config=./config/crypto-config-orgA.yaml --output="organizations"
  cryptogen generate --config=./config/crypto-config-orgB.yaml --output="organizations"
  cryptogen generate --config=./config/crypto-config-orderer.yaml --output="organizations"
}



function createNetworkContainers() {
  echo "Creating Network Containers"
  docker-compose -f $COMPOSE_FILE_BASE up -d
}


function networkDown() {
# Remove Crypto Material
deleteCryptoMaterials
deleteNetworkConatainers
}

function deleteNetworkConatainers() {
  echo "Removing Network Containers"
  docker-compose -f $COMPOSE_FILE_BASE down --volumes --remove-orphans
 }

 # Function to Removing Crypto Material
function deleteCryptoMaterials() {
  echo "Removing Crypto Materials"
  rm -rf organizations
  rm -rf channel-artifacts
}


: ${CHANNEL_NAME:="mychannel"}

if [ ! -d "channel-artifacts" ]; then
  echo "Creating channel-artifacts Directory"
	mkdir channel-artifacts
fi
 
# Set environment variables for the peer org
setGlobals() {
  local USING_ORG=""
  if [ -z "$OVERRIDE_ORG" ]; then
    USING_ORG=$1
  else
    USING_ORG="${OVERRIDE_ORG}"
  fi

}

createChannelGenesisBlock(){
  setGlobals $ORG
	which configtxgen
	configtxgen -profile ChannelUsingRaft -outputBlock ./channel-artifacts/${CHANNEL_NAME}.block -channelID $CHANNEL_NAME

  echo "createChannelGenesisBlock Created Successfully"

}


function createChannel(){

  export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
  export ORDERER_ADMIN_TLS_SIGN_CERT=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt 
  export ORDERER_ADMIN_TLS_PRIVATE_KEY=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key 
  osnadmin channel join --channelID ${CHANNEL_NAME} --config-block ./channel-artifacts/${CHANNEL_NAME}.block -o localhost:7053 --ca-file "$ORDERER_CA" --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY" >> log.txt 2>&1

  echo "Channel Created Successfully"
}

function joinChannel(){

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgAMSP
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgA.example.com/peers/peer0.orgA.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgA.example.com/users/Admin@orgA.example.com/msp
  export CORE_PEER_ADDRESS=localhost:7051

 BLOCKFILE="./channel-artifacts/${CHANNEL_NAME}.block"
 peer channel join -b $BLOCKFILE >&log.txt
 peer channel list
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgBMSP
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgB.example.com/peers/peer0.orgB.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgB.example.com/users/Admin@orgB.example.com/msp
  export CORE_PEER_ADDRESS=localhost:9051

  BLOCKFILE="./channel-artifacts/${CHANNEL_NAME}.block"
  peer channel join -b $BLOCKFILE >&log2.txt
  peer channel list
  echo "OrgA OrgB proposal submitted successfully!"
}

fetchChannelConfig() {

  # Setting Anchor Peers
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgAMSP
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgA.example.com/peers/peer0.orgA.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgA.example.com/users/Admin@orgA.example.com/msp
  export CORE_PEER_ADDRESS=localhost:7051

: ${CHANNEL_NAME:="mychannel"}
: ${HOST:="peer0.orgA.example.com"}
: ${PORT:="7051"}

  export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
  peer channel fetch config ./channel-artifacts/config_block.pb -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"
  configtxlator proto_decode --input ${PWD}/channel-artifacts/config_block.pb --type common.Block --output ${PWD}/channel-artifacts/config_block.json 
  jq .data.data[0].payload.data.config ${PWD}/channel-artifacts/config_block.json >"${PWD}/channel-artifacts/${CORE_PEER_LOCALMSPID}config.json"
  
  jq '.channel_group.groups.Application.groups.'${CORE_PEER_LOCALMSPID}'.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "'$HOST'","port": '$PORT'}]},"version": "0"}}' ${PWD}/channel-artifacts/${CORE_PEER_LOCALMSPID}config.json > ${PWD}/channel-artifacts/${CORE_PEER_LOCALMSPID}modified_config.json

  jq '.channel_group.groups.Application.groups.OrgBMSP.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "peer0.orgB.example.com","port": 9051}]},"version": "0"}}' ${PWD}/channel-artifacts/${CORE_PEER_LOCALMSPID}modified_config.json > ${PWD}/channel-artifacts/OrgBMSPmodified_config.json

  #configtxlator proto_encode --input "${ORIGINAL}" --type common.Config --output ${PWD}/channel-artifacts/original_config.pb
  configtxlator proto_encode --input ${PWD}/channel-artifacts/OrgBMSPmodified_config.json --type common.Config --output ${PWD}/channel-artifacts/modified_config.pb
  configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original ${PWD}/channel-artifacts/config_block.pb --updated ${PWD}/channel-artifacts/modified_config.pb --output ${PWD}/channel-artifacts/config_update.pb
  configtxlator proto_decode --input ${PWD}/channel-artifacts/config_update.pb --type common.ConfigUpdate --output ${PWD}/channel-artifacts/config_update.json
  echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat ${PWD}/channel-artifacts/config_update.json)'}}}' | jq . > ${PWD}/channel-artifacts/config_update_in_envelope.json
  configtxlator proto_encode --input ${PWD}/channel-artifacts/config_update_in_envelope.json --type common.Envelope --output ${PWD}/channel-artifacts/config_update_envelope.pb

  peer channel signconfigtx -f ${PWD}/channel-artifacts/config_update_envelope.pb

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgBMSP
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgB.example.com/peers/peer0.orgB.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgB.example.com/users/Admin@orgB.example.com/msp
  export CORE_PEER_ADDRESS=localhost:9051  

  peer channel signconfigtx -f ${PWD}/channel-artifacts/config_update_envelope.pb

}


# --- Main Funcation --- Start ---
#====================================

function main() {

  ARGS=$1
    #echo "Arguments = $ARGS"

if [ $ARGS == "down" ]; then

  echo "Network Getting Down";

  networkDown
  
elif [ $ARGS == "up" ]; then

  echo "Network Getting UP"

# Calling  Custom Funcations

  createCryptoMaterials
  createNetworkContainers
  createChannelGenesisBlock
  createChannel
  joinChannel
  
  
elif [ $ARGS == "test" ]; then

  echo "Test Arguments"

  fetchChannelConfig

elif [ $ARGS == " " ]; then

  echo "Invalid Input"
fi

}

#---- Main Funcation --- End ----

#Calling Main Function 

#set -x
main $1
#set +x
