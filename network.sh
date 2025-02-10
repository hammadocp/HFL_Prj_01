#!/bin/bash

export PATH=./bin:$PATH
export FABRIC_CFG_PATH=./config

CHANNEL_NAME="mychannel"
# use this as the default docker-compose yaml definition
COMPOSE_FILE_BASE=docker-compose-Prj01-net.yaml

function createCryptoMaterials() {
  echo "Generating Crypto Materials for OrgA, OrgB and Orderer organizations "

  cryptogen generate --config=./config/crypto-config-orgA.yaml --output="organizations"
  cryptogen generate --config=./config/crypto-config-orgB.yaml --output="organizations"
  cryptogen generate --config=./config/crypto-config-orderer.yaml --output="organizations"
}

# Function to Removing Crypto Material
function cleanup() {
  echo "Removing Crypto Materials"
  rm -rf organizations
  rm -rf channel-artifacts
  rm -rf log*
}

function deleteNetworkConatainers() {
  echo "Removing Network Containers"

  docker-compose -f $COMPOSE_FILE_BASE down --volumes --remove-orphans
}

function createNetworkContainers() {
  echo "Creating Network Containers"

  docker-compose -f $COMPOSE_FILE_BASE up -d
}

function networkDown() {
  echo "Deleting and cleaning up fabric network"

  deleteNetworkConatainers
  cleanup
}

createChannelGenesisBlock() {
  echo "Creating Channel Genesis Block"

  if [ ! -d "channel-artifacts" ]; then
    echo "Creating channel-artifacts Directory"
    mkdir channel-artifacts
  fi
  configtxgen -profile ChannelUsingRaft -outputBlock ./channel-artifacts/${CHANNEL_NAME}.block -channelID $CHANNEL_NAME
}

function joinChannel() {
  echo "Joining channel"

  BLOCKFILE="./channel-artifacts/${CHANNEL_NAME}.block"

  export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
  export ORDERER_ADMIN_TLS_SIGN_CERT=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt
  export ORDERER_ADMIN_TLS_PRIVATE_KEY=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key
  osnadmin channel join --channelID ${CHANNEL_NAME} --config-block $BLOCKFILE -o localhost:7053 --ca-file "$ORDERER_CA" --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY"

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgAMSP
  export CORE_PEER_ADDRESS=localhost:7051
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgA.example.com/peers/peer0.orgA.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgA.example.com/users/Admin@orgA.example.com/msp
  peer channel join -b $BLOCKFILE

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgBMSP
  export CORE_PEER_ADDRESS=localhost:9051
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgB.example.com/peers/peer0.orgB.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgB.example.com/users/Admin@orgB.example.com/msp
  peer channel join -b $BLOCKFILE
}

fetchChannelConfig() {
  echo "Fetching channel config"

  CHANNEL_NAME="mychannel"

  export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgAMSP
  export CORE_PEER_ADDRESS=localhost:7051
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgA.example.com/peers/peer0.orgA.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgA.example.com/users/Admin@orgA.example.com/msp

  peer channel fetch config ./channel-artifacts/${CHANNEL_NAME}_config_block.pb -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"
  configtxlator proto_decode --input ./channel-artifacts/${CHANNEL_NAME}_config_block.pb --type common.Block --output ./channel-artifacts/config_block.json
  jq .data.data[0].payload.data.config ./channel-artifacts/config_block.json >"./channel-artifacts/${CHANNEL_NAME}_config.json"
}

addAnchorPeerInConfig() {
  echo "Adding anchor peer to the channel config"

  CHANNEL_NAME="mychannel"

  jq '.channel_group.groups.Application.groups.OrgAMSP.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "peer0.orgA.example.com","port": 7051}]},"version": "0"}}' ./channel-artifacts/${CHANNEL_NAME}_config.json >./channel-artifacts/${CHANNEL_NAME}_OrgA_config.json
  jq '.channel_group.groups.Application.groups.OrgBMSP.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "peer0.orgB.example.com","port": 9051}]},"version": "0"}}' ./channel-artifacts/${CHANNEL_NAME}_OrgA_config.json >./channel-artifacts/${CHANNEL_NAME}_OrgB_config.json
}

updateAnchorPeer() {
  echo "Updating anchor peer to the channel"

  CHANNEL_NAME="mychannel"

  configtxlator proto_encode --input ./channel-artifacts/${CHANNEL_NAME}_config.json --type common.Config --output ./channel-artifacts/${CHANNEL_NAME}_config.pb
  configtxlator proto_encode --input ./channel-artifacts/${CHANNEL_NAME}_OrgB_config.json --type common.Config --output ./channel-artifacts/${CHANNEL_NAME}_update_config.pb
  configtxlator compute_update --channel_id ${CHANNEL_NAME} --original ./channel-artifacts/${CHANNEL_NAME}_config.pb --updated ./channel-artifacts/${CHANNEL_NAME}_update_config.pb --output ./channel-artifacts/${CHANNEL_NAME}_updated_config.pb
  configtxlator proto_decode --input ./channel-artifacts/${CHANNEL_NAME}_updated_config.pb --type common.ConfigUpdate --output ./channel-artifacts/${CHANNEL_NAME}_updated_config.json
  echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat ./channel-artifacts/${CHANNEL_NAME}_updated_config.json)'}}}' | jq . >./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.json
  configtxlator proto_encode --input ./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.json --type common.Envelope --output ./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.tx

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID=OrgAMSP
  export CORE_PEER_ADDRESS=localhost:7051
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgA.example.com/peers/peer0.orgA.example.com/tls/ca.crt
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgA.example.com/users/Admin@orgA.example.com/msp
  peer channel signconfigtx -f ./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.tx

  CORE_PEER_TLS_ENABLED=true
  CORE_PEER_LOCALMSPID=OrgBMSP
  CORE_PEER_ADDRESS=localhost:9051
  CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/orgB.example.com/peers/peer0.orgB.example.com/tls/ca.crt
  CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/orgB.example.com/users/Admin@orgB.example.com/msp
  peer channel signconfigtx -f ./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.tx

  peer channel update -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c $CHANNEL_NAME -f ./channel-artifacts/${CHANNEL_NAME}_updated_config_envelope.tx --tls --cafile "$ORDERER_CA"
}

addAnchorPeer() {
  fetchChannelConfig
  addAnchorPeerInConfig
  updateAnchorPeer
}

function createChannel() {
  createChannelGenesisBlock
  joinChannel
}

# --- Main Funcation --- Start ---
#====================================
function main() {
  ARGS=$1
  #echo "Arguments = $ARGS"

  if [ $ARGS == "down" ]; then
    echo "Network Getting Down"

    networkDown

  elif [ $ARGS == "up" ]; then
    echo "Network Getting up"

    createCryptoMaterials
    createNetworkContainers
    createChannel
    sleep 2
    addAnchorPeer

  elif [ $ARGS == "test" ]; then
    echo "Testing someting"

    addAnchorPeer

  elif [ $ARGS == " " ]; then
    echo "Invalid Input"
  fi
}
#====================================
#---- Main Funcation --- End ----

#Calling Main Function
#set -x
main $1
#set +x
