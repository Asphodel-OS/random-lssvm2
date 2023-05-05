# Forked from https://github.com/ZeframLou/create3-factory/blob/d68b7bcdd46fc490d76a6ed4cf02add6ed2ca740/deploy/deploy.sh
# Added --via-ir flag for added gas efficiency

deploy() {
	NETWORK=$1

	forge build --skip test --via-ir
	RAW_RETURN_DATA=$(forge script script/Deploy.s.sol --skip test --via-ir -f $NETWORK -vvvv --json --silent --broadcast --verify --skip-simulation)
	RETURN_DATA=$(echo $RAW_RETURN_DATA | jq -r '.returns' 2> /dev/null)

	factory=$(echo $RETURN_DATA | jq -r '.factory.value')

	saveContract $NETWORK CREATE3Factory $factory
}

saveContract() {
	NETWORK=$1
	CONTRACT=$2
	ADDRESS=$3

	ADDRESSES_FILE=./deployments/$NETWORK.json

	# create an empty json if it does not exist
	if [[ ! -e $ADDRESSES_FILE ]]; then
		echo "{}" >"$ADDRESSES_FILE"
	fi
	result=$(cat "$ADDRESSES_FILE" | jq -r ". + {\"$CONTRACT\": \"$ADDRESS\"}")
	printf %s "$result" >"$ADDRESSES_FILE"
}

deploy $1