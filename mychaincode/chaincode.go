package main

import "github.com/hyperledger/fabric-contract-api-go/v2/contractapi"

type MyContract struct {
	contractapi.Contract 
}

func main ()  {
	myContract,err:=contractapi.NewChainCode(&MyContract{})
	if err !=nil {
		log.Panicf("Error While Creating ChainCode",err)
	}
	err=myContract.start()
	if err !=nil {
		log.Panicf("Error While Starting ChainCode",err)
}