#!/bin/bash

set -eo pipefail

if [ -z $AWS_ACCOUNT_ID ]; then
    echo "AWS_ACCOUNT_ID environment variable is not set."
    exit 1
fi

if [ -z $AWS_DEFAULT_REGION ]; then
    echo "AWS_DEFAULT_REGION environment variable is not set."
    exit 1
fi

if [ -z $ENVOY_IMAGE ]; then
    echo "ENVOY_IMAGE environment variable is not set to App Mesh Envoy, see https://docs.aws.amazon.com/app-mesh/latest/userguide/envoy.html"
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
PROJECT_NAME="howto-k8s-ingress-gateway"
APP_NAMESPACE=${PROJECT_NAME}
MESH_NAME=${PROJECT_NAME}

ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
ECR_IMAGE_PREFIX="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${PROJECT_NAME}"
COLOR_APP_IMAGE="${ECR_IMAGE_PREFIX}/colorapp"
MANIFEST_VERSION="${1:-v1beta2}"
AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d. -f1)

error() {
    echo $1
    exit 1
}

check_k8s_virtualgateway() {
    #check CRD
    crd=$(kubectl get crd virtualgateways.appmesh.k8s.aws -o json )
    if [ -z "$crd" ]; then
        error "$PROJECT_NAME requires virtualgateways.appmesh.k8s.aws CRD to support Ingress gateway. See https://github.com/aws/aws-app-mesh-controller-for-k8s/blob/master/CHANGELOG.md"
    else
        echo "CRD check passed!"
    fi
}

check_k8s_gatewayroutes() {
    #check CRD
    crd=$(kubectl get crd gatewayroutes.appmesh.k8s.aws -o json )
    if [ -z "$crd" ]; then
        error "$PROJECT_NAME requires gatewayroutes.appmesh.k8s.aws CRD to support Ingress gateway. See https://github.com/aws/aws-app-mesh-controller-for-k8s/blob/master/CHANGELOG.md"
    else
        echo "CRD check passed!"
    fi
}

check_appmesh_k8s() {
    #check aws-app-mesh-controller version
    if [ "$MANIFEST_VERSION" = "v1beta2" ]; then
        currentver=$(kubectl get deployment -n appmesh-system appmesh-controller -o json | jq -r ".spec.template.spec.containers[].image" | cut -f2 -d ':'|tail -n1)
        requiredver="v1.0.0"
        check_k8s_virtualgateway
        check_k8s_gatewayroutes
    else
        error "$PROJECT_NAME unexpected manifest version input: $MANIFEST_VERSION. Should be v1beta2 or v1beta1 based on the AppMesh controller version. See https://github.com/aws/aws-app-mesh-controller-for-k8s/blob/master/CHANGELOG.md"
    fi

    if [ "$(printf '%s\n' "$requiredver" "$currentver" | sort -V | head -n1)" = "$requiredver" ]; then
        echo "aws-app-mesh-controller check passed! $currentver >= $requiredver"
    else
        error "$PROJECT_NAME requires aws-app-mesh-controller version >=$requiredver but found $currentver. See https://github.com/aws/aws-app-mesh-controller-for-k8s/blob/master/CHANGELOG.md"
    fi
}

ecr_login() {
        if [ $AWS_CLI_VERSION -eq 1 ]; then
            $(aws ecr get-login --no-include-email)
        elif [ $AWS_CLI_VERSION -eq 2 ]; then
            aws ecr get-login-password | docker login --username AWS --password-stdin ${ECR_URL}
        else
            echo "Invalid AWS CLI version"
            exit 1
        fi
}

deploy_images() {
    for app in colorapp; do
        aws ecr describe-repositories --repository-name $PROJECT_NAME/$app >/dev/null 2>&1 || aws ecr create-repository --repository-name $PROJECT_NAME/$app
        docker build -t ${ECR_IMAGE_PREFIX}/${app} ${DIR}/${app}
        ecr_login
        docker push ${ECR_IMAGE_PREFIX}/${app}
    done
}

deploy_app() {
    EXAMPLES_OUT_DIR="${DIR}/_output/"
    mkdir -p ${EXAMPLES_OUT_DIR}
    eval "cat <<EOF
$(<${DIR}/${MANIFEST_VERSION}/manifest.yaml.template)
EOF
" >${EXAMPLES_OUT_DIR}/manifest.yaml

    kubectl apply -f ${EXAMPLES_OUT_DIR}/manifest.yaml
}

main() {
    check_appmesh_k8s

    if [ -z $SKIP_IMAGES ]; then
        echo "deploy images..."
        deploy_images
    fi

    deploy_app
}

main
