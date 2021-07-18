#!/usr/bin/env bash

GRACE_TIME="20s"
REGION="us-east-1"
STAGE="test"
API_NAME=api_$(date +"%Y%m%d_%H%M%S")
DOCKER_FILE="docker-compose.yml"
ENV_FILE="./.env"
LOCALSTACK_ENDPOINT="http://localhost:4566"

function fail() {
    echo $2
    exit $1
}

if [[ -f $ENV_FILE ]]; then
    echo "Sourcing environment variables..."
    source $ENV_FILE
else
    fail 9 "$ENV_FILE not present..."
fi

echo "Building lambda..."
GOOS=linux go build -o api ./ && \
    zip api.zip api && \
    rm -rf api

echo "Removing old containers..."
docker-compose -f ${DOCKER_FILE} down --remove-orphans

echo "Building new localstack environment..."
docker-compose -f ${DOCKER_FILE} up -d

echo "Grace time for $GRACE_TIME..."
sleep $GRACE_TIME && echo "Grace time ended..."

echo "Generated API name: $API_NAME"

awslocal elasticache create-cache-cluster \
    --cache-cluster-id "testcenters_cache" \
    --engine redis \
    --cache-node-type cache.m5.large \
    --num-cache-nodes 1

echo "Creating lambda function..."
awslocal lambda create-function \
    --region ${REGION} \
    --function-name ${API_NAME} \
    --runtime go1.x \
    --handler api \
    --timeout 30 \
    --memory-size 512 \
    --zip-file fileb://api.zip \
    --role arn:aws:iam::123456:role/irrelevant

[ $? == 0 ] || fail 1 "Failed: AWS / lambda / create-function"

LAMBDA_ARN=$(awslocal lambda list-functions --query "Functions[?FunctionName==\`${API_NAME}\`].FunctionArn" --output text --region ${REGION})

echo "Creating REST API..."
awslocal apigateway create-rest-api \
    --region ${REGION} \
    --name ${API_NAME}

[ $? == 0 ] || fail 2 "Failed: AWS / apigateway / create-rest-api"

API_ID=$(awslocal apigateway get-rest-apis --query "items[?name==\`${API_NAME}\`].id" --output text --region ${REGION})
PARENT_RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/`].id' --output text --region ${REGION})

awslocal apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${PARENT_RESOURCE_ID} \
    --path-part "{somethingId}"

[ $? == 0 ] || fail 3 "Failed: AWS / apigateway / create-resource"

RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/{somethingId}`].id' --output text --region ${REGION})

awslocal apigateway put-method \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --request-parameters "method.request.path.somethingId=true" \
    --authorization-type "NONE" \

[ $? == 0 ] || fail 4 "Failed: AWS / apigateway / put-method"

echo "Creating REST API integration..."
awslocal apigateway put-integration \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --passthrough-behavior WHEN_NO_MATCH \

[ $? == 0 ] || fail 5 "Failed: AWS / apigateway / put-integration"

echo "Creating REST API deployment..."
awslocal apigateway create-deployment \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --stage-name ${STAGE} \

[ $? == 0 ] || fail 6 "Failed: AWS / apigateway / create-deployment"

ENDPOINT=$LOCALSTACK_ENDPOINT/restapis/${API_ID}/${STAGE}/_user_request_

echo "API endpoint:"
echo ${ENDPOINT}

echo -e "\nAll good..."
