#!/bin/bash
set -e

### command with all arguments
##### deploy-cp4i
## ./deploy-cp4i.sh --base-path=/home/ec2-user --license=accept --ibm-entitlement-key=eXAiOiJKV1QiABCDeaasdabGciOiJIUzI1NiJ9


function subscription_status() {
    SUB_NAMESPACE=${1}
    SUBSCRIPTION=${2}

    CSV=$(${BIN_DIR}/oc get subscription -n ${SUB_NAMESPACE} ${SUBSCRIPTION} -o json | jq -r '.status.currentCSV')
    if [[ "$CSV" == "null" ]]; then
        STATUS="PendingCSV"
    else
        STATUS=$(${BIN_DIR}/oc get csv -n ${SUB_NAMESPACE} ${CSV} -o json | jq -r '.status.phase')
    fi
    echo $STATUS
}

function wait_for_subscription() {
    SUB_NAMESPACE=${1}
    export SUBSCRIPTION=${2}
    
    # Set default timeout of 15 minutes
    if [[ -z ${3} ]]; then
        TIMEOUT=15
    else
        TIMEOUT=${3}
    fi

    export TIMEOUT_COUNT=$(( $TIMEOUT * 60 / 30 ))

    count=0;
    while [[ $(subscription_status $SUB_NAMESPACE $SUBSCRIPTION) != "Succeeded" ]]; do
        echo "INFO: Waiting for subscription $SUBSCRIPTION to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
        sleep 30
        count=$(( $count + 1 ))
        if (( $count > $TIMEOUT_COUNT )); then
            echo "ERROR: Timeout exceeded waiting for subscription $SUBSCRIPTION to be ready"
            exit 1
        fi
    done
}

function catalog_status() {
    # Gets the status of a catalogsource
    # Usage:
    #      catalog_status CATALOG

    CATALOG=${1}

    CAT_STATUS="$(${BIN_DIR}/oc get catalogsource -n openshift-marketplace $CATALOG -o json | jq -r '.status.connectionState.lastObservedState')"
    echo $CAT_STATUS
}

function wait_for_catalog() {
    # Waits for a catalog source to be ready
    # Usage:
    #      wait_for_catalog CATALOG [TIMEOUT]

    CATALOG=${1}
    # Set default timeout of 15 minutes
    if [[ -z ${2} ]]; then
        TIMEOUT=15
    else
        TIMEOUT=${2}
    fi

    export TIMEOUT_COUNT=$(( $TIMEOUT * 60 / 30 ))

    count=0;
    while [[ $(catalog_status $CATALOG) != "READY" ]]; do
        echo "INFO: Waiting for catalog source $CATALOG to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
        sleep 30
        count=$(( $count + 1 ))
        if (( $count > $TIMEOUT_COUNT )); then
            echo "ERROR: Timeout exceeded waiting for catalog source $CATALOG to be ready"
            exit 1
        fi
    done   
}


function wait_for_cluster_operators() {
# Login to an OpenShift cluster. Must be logged into az cli beforehand and az cli must be in PATH
# Usage:
#        wait_for_cluster_operators API_SERVER OCP_USERNAME OCP_PASSWORD BIN_DIR 
#

    echo "INFO: Checking for cluster operator status"

    # Wait for cluster operators to be available
    count=0
    while ${BIN_DIR}/oc get clusteroperators | awk '{print $4}' | grep True; do
        echo "INFO: Waiting on cluster operators to be availabe. Waited $count minutes. Will wait up to 30 minutes."
        sleep 60
        count=$(( $count + 1 ))
        if (( $count > 30 )); then
            echo "ERROR: Timeout waiting for cluster operators to be available"
            exit 1;
        fi
    done
    echo "INFO: Cluster operators are ready"

}

function validate_cmd_options() {
    if [[ -z $BIN_DIR ]]; then export BIN_DIR="/usr/local/bin"; fi
    if [[ -z $TMP_DIR ]]; then TMP_DIR="${WORKSPACE_DIR}/tmp"; fi
    if [[ -z $CLUSTER_SCOPED ]]; then CLUSTER_SCOPED="false"; fi
    if [[ -z $REPLICAS ]]; then REPLICAS=1; fi

    if [ -z $ibm_entitlement_key ]; then
            echo "ibm_entitlement_key cannot be blank or empty"
            exit 1;
    fi

    if [ -z $namespace ]; then
        namespace="cp4i"
    fi

    if [ -z $intance_namespace ]; then
        intance_namespace="cp4i"
    fi

    if [[ -z $license || $license != "accept" ]]; then
        echo "accept the license. license value must be accept/reject "

    fi
    
    if [ -z $version ]; then
        version="2022.2.1"
    fi

    if [ -z $storage_class ]; then
        storage_class="efs-nfs-client"
    fi

    if [ -z $license_id ]; then
        license_id="L-RJON-CD3JKX"
    fi

    # validate base_path
    if [ -z $base_path ]; then
        base_path=$(pwd)
    fi


    if [ -z $info_path ]; then
        echo ".info file path is blank or empty. So, it'll try to retrieve from default path"
        info_path=$default_info_path
    fi

    # validate info_path
    if [ -z $cred_path ]; then
        echo ".cred file path is blank or empty. So, it'll try to retrieve from default path"
        cred_path=$default_cred_path
    fi
}

# extract_login_cred
function extract_login_cred() {
    echo "cred_path..$cred_path"
    credfile=$(cat $cred_path)
    
    # read cluster_url from .cred
    if [ -z $cluster_url ]; then
      cluster_url=$(echo "$credfile" | grep -o 'https://[^ ]*')
    fi
    
    # read cluster_username from .cred
    if [ -z $cluster_username ]; then
      cluster_username=$(echo "$credfile" | grep -oE -- '--username ([^ ]+)' | cut -d' ' -f2)
    fi

    # read cluster_password from .cred
    if [ -z $cluster_password ]; then
      cluster_password=$(echo "$credfile" | grep -oE -- '--password ([^ ]+)' | cut -d' ' -f2)
    fi
    
    # read region from ec2 metadata
    if [ -z $region ]; then
      region=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
    fi

    echo "cluster_url: $cluster_url, cluster_username: $cluster_username, cluster_password: $cluster_password, subnets: $subnets"

    aws_region=$region
    
    echo "***** OC credentials are extracted *****"
}

# oc login
function oc_login() {
    oc login $cluster_url --username $cluster_username --password $cluster_password --insecure-skip-tls-verify
    if [ $? == 0 ]; then
        echo "oc login successfully!!"
    else
        echo "oc login failed!!"
        exit 1;
    fi

    echo "***** OC login is successful *****"
}

##### script execution is started from below #####

SHORT=bp:,iek:,ns:,ins:,lc:,ver:,sc:,lcid:,h
LONG=base-path:,ibm-entitlement-key:,namespace:,intance-namespace:,license:,version:,storage-class:,license-id:,help
OPTS=$(getopt -a -n weather --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    -bp | --base-path )
      base_path="$2"
      shift 2
      ;;
    -iek | --ibm-entitlement-key )
      ibm_entitlement_key="$2"
      shift 2
      ;;
    -ns | --namespace )
      namespace="$2"
      shift 2
      ;;
    -ins | --intance-namespace )
      intance_namespace="$2"
      shift 2
      ;;
    -lc | --license )
      license="$2"
      shift 2
      ;;
    -ver | --version )
      version="$2"
      shift 2
      ;;
    -sc | --storage-class )
      storage_class="$2"
      shift 2
      ;;
    -lcid | --license-id )
      license_id="$2"
      shift 2
      ;;
    -h | --help)
      "This is a deploy cp4i script"
      exit 2
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Invalid option: $1"
      ;;
  esac
done

export installer_workspace=$base_path/installer-files
export default_cred_path=$installer_workspace/.cred
export default_info_path=$installer_workspace/.info


validate_cmd_options
echo "***** all cp4i cmd options validation is completed *****"

PN_CASE_VERSION="1.7.10"
PN_CATALOG_IMAGE="icr.io/cpopen/ibm-integration-platform-navigator-catalog@sha256:3435a5d0e2375d0524bd3baaa0dad772280efe6cacc13665ac8b2760ad3ebb35"
PN_OPERATOR_CHANNEL="v6.0"
CS_CASE_VERSION="1.15.12"
CS_CATALOG_IMAGE="icr.io/cpopen/ibm-common-service-catalog@sha256:fbf8ef961f3ff3c98ca4687f5586741ea97085ab5b78691baa056a5d581eecf5"
CS_OPERATOR_CHANNEL="v3"

# APIC
APIC_CASE_VERSION="4.0.4"
APIC_CATALOG_IMAGE="icr.io/cpopen/ibm-apiconnect-catalog@sha256:a89b72f4794b74caec423059d0551660951c9d772d9892789d3bdf0407c3f61a"
APIC_OPERATOR_CHANNEL="v3.3"

# App Connect
APPCONNECT_CASE_VERSION="5.0.7"
APPCONNECT_CATALOG_IMAGE="icr.io/cpopen/appconnect-operator-catalog@sha256:ccb9190be75128376f64161dccfb6d64915b63207206c9b74d05611ab88125ce"
APPCONNECT_OPERATOR_CHANNEL="v5.0-lts"

# Aspera + Redis
ASPERA_CASE_VERSION="1.5.8"
ASPERA_CATALOG_IMAGE="icr.io/cpopen/aspera-hsts-catalog@sha256:ba2b97642692c627382e738328ec5e4b566555dcace34d68d0471439c1efc548"
ASPERA_OPERATOR_CHANNEL="v1.5"
REDIS_CASE_VERSION="1.6.6"
REDIS_CATALOG_IMAGE="icr.io/cpopen/ibm-cloud-databases-redis-catalog@sha256:fddf96636005a9c276aec061a3b514036ce6d79bd91fd7e242126b2f52394a78"
#REDIS_OPERATOR_CHANNEL=""  

# Event Streams
ES_CASE_VERSION="3.2.0"
ES_CATALOG_IMAGE="icr.io/cpopen/ibm-eventstreams-catalog@sha256:ac87cfecba0635a67c7d9b6c453c752cba9b631ffdd340223e547809491eb708"
ES_OPERATOR_CHANNEL="v3.2"

# Operations Dashboard
OD_CASE_VERSION="2.6.11"
OD_CATALOG_IMAGE="icr.io/cpopen/ibm-integration-operations-dashboard-catalog@sha256:756c4e3aa31c9ee9641dcdac89566d8f3a78987160d75ab010a7e0eadb91a873"
OD_OPERATOR_CHANNEL="v2.6-lts"

# Automation Assets
AA_CASE_VERSION="1.5.9"
AA_CATALOG_IMAGE="icr.io/cpopen/ibm-integration-asset-repository-catalog@sha256:1af42da7f7c8b12818d242108b4db6f87862504f1c57789213539a98720b0fed"
AA_OPERATOR_CHANNEL="v1.5"

# DataPower
DATAPOWER_CASE_VERSION="1.6.7"
DATAPOWER_CATALOG_IMAGE="icr.io/cpopen/datapower-operator-catalog@sha256:1b3e967cfa0c4615ad183ba0f19cca5f64fbad9eb833ee5dad9b480b38d80010"
DATAPOWER_OPERATOR_CHANNEL="v1.6"

# MQ
MQ_CASE_VERSION="2.0.12"
MQ_CATALOG_IMAGE="icr.io/cpopen/ibm-mq-operator-catalog@sha256:ea21ed79f877458392ac160a358f72a4b33c755220f5d9eaccfdb89ab2232a3b"
MQ_OPERATOR_CHANNEL="v2.0"

extract_login_cred

oc_login

API_SERVER=$cluster_url
LICENSE=$license
NAMESPACE=$namespace
INSTANCE_NAMESPACE=$intance_namespace
STORAGE_CLASS=$storage_class
WORKSPACE_DIR=$installer_workspace
VERSION=$version
LICENSE_ID=$license_id
IBM_ENTITLEMENT_KEY=$ibm_entitlement_key


echo "INFO: Cluster is set to : $API_SERVER"
echo "INFO: License acceptance is set to : $LICENSE"
echo "INFO: Namespace is set to : $NAMESPACE"
echo "INFO: Instance namespace is set to : $INSTANCE_NAMESPACE"
echo "INFO: Storage class for instance is set to : $STORAGE_CLASS"
echo "INFO: Replicas for instance is set to : $REPLICAS"
echo "INFO: Operator cluster scoped is : $CLUSTER_SCOPED"
echo "INFO: Workspace directory is set to : $WORKSPACE_DIR"
echo "INFO: Binary directory is set to : $BIN_DIR"
echo "INFO: Temp directory is set to : $TMP_DIR"
echo "INFO: Software version is set to : $VERSION"
echo "INFO: Software license is set to : $LICENSE_ID"

mkdir -p "$TMP_DIR"



# Wait for cluster operators to be available
wait_for_cluster_operators

# Create namespace if it does not exist
if [[ -z $(${BIN_DIR}/oc get namespaces | grep ${NAMESPACE}) ]]; then
    echo "INFO: Creating namespace ${NAMESPACE}"
    ${BIN_DIR}/oc create namespace $NAMESPACE
else
    echo "INFO: Using existing namespace $NAMESPACE"
fi

# Create entitlement key secret for image pull if required
if [[ -z $IBM_ENTITLEMENT_KEY ]]; then
    echo "INFO: Now setting IBM Entitlement key"
    if [[ $LICENSE == "accept" ]]; then
        echo "ERROR: License accepted but entitlement key not provided"
        exit 1
    fi
else
    if [[ -z $(${BIN_DIR}/oc get secret -n ${NAMESPACE} | grep ibm-entitlement-key) ]]; then
        echo "INFO: Creating entitlement key secret"
        ${BIN_DIR}/oc create secret docker-registry ibm-entitlement-key --docker-server=cp.icr.io --docker-username=cp --docker-password=$IBM_ENTITLEMENT_KEY -n $NAMESPACE
    else
        echo "INFO: Using existing entitlement key secret"
    fi
fi

# Install catalog sources
if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-apiconnect-catalog) ]]; then
    echo "INFO: Installing IBM API Connect catalog source"
    if [[ -f ${WORKSPACE_DIR}/api-connect-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/api-connect-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/api-connect-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-apiconnect-catalog
  namespace: openshift-marketplace
spec:
  displayName: "APIC from CASE ${APIC_CASE_VERSION}"
  image: ${APIC_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/api-connect-catalogsource.yaml
else
    echo "INFO: IBM API Connect catalog source already installed"
fi


wait_for_catalog ibm-apiconnect-catalog
echo "INFO: Catalog source ibm-apiconnect-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-appconnect-catalog) ]]; then
    echo "INFO: Installed IBM App Connect catalog source"
    if [[ -f ${WORKSPACE_DIR}/app-connect-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/app-connect-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/app-connect-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-appconnect-catalog
  namespace: openshift-marketplace
spec:
  displayName: "App Connect from CASE ${APPCONNECT_CASE_VERSION}"
  image: ${APPCONNECT_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/app-connect-catalogsource.yaml
else
    echo "INFO: IBM App Connect catalog source already installed"
fi

wait_for_catalog ibm-appconnect-catalog
echo "INFO: Catalog source ibm-appconnect-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-aspera-hsts-operator-catalog) ]]; then
    echo "INFO: Installed IBM Aspera catalog source"
    if [[ -f ${WORKSPACE_DIR}/aspera-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/aspera-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/aspera-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-aspera-hsts-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "Aspera from CASE ${ASPERA_CASE_VERSION}"
  image: ${ASPERA_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/aspera-catalogsource.yaml
else
    echo "INFO: IBM Aspera catalog source already installed"
fi

wait_for_catalog ibm-aspera-hsts-operator-catalog
echo "INFO: Catalog source ibm-aspera-hsts-operator-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-cloud-databases-redis-catalog) ]]; then
    echo "INFO: Installed IBM Cloud databases Redis catalog source"
    if [[ -f ${WORKSPACE_DIR}/redis-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/redis-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/redis-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-cloud-databases-redis-catalog
  namespace: openshift-marketplace
spec:
  displayName: "Redis from CASE ${REDIS_CASE_VERSION}"
  image: ${REDIS_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/redis-catalogsource.yaml
else
    echo "INFO: IBM Cloud databases Redis catalog source already installed"
fi

wait_for_catalog ibm-cloud-databases-redis-catalog
echo "INFO: Catalog source ibm-cloud-databases-redis-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-common-service-catalog) ]]; then
    echo "INFO: Installing IBM Common services catalog source"
    if [[ -f ${WORKSPACE_DIR}/common-svcs-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/common-svcs-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/common-svcs-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-common-service-catalog
  namespace: openshift-marketplace
spec:
  displayName: "IBM Foundation Services from CASE ${CS_CASE_VERSION}"
  image: ${CS_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/common-svcs-catalogsource.yaml
else
    echo "INFO: IBM common services catalog source already installed"
fi

wait_for_catalog ibm-common-service-catalog
echo "INFO: Catalog source ibm-common-service-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-datapower-operator-catalog) ]]; then
    echo "INFO: Installing IBM DataPower catalog source"
    if [[ -f ${WORKSPACE_DIR}/data-power-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/data-power-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/data-power-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-datapower-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "DataPower from CASE ${DATAPOWER_CASE_VERSION}"
  image: ${DATAPOWER_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/data-power-catalogsource.yaml
else
    echo "INFO: IBM DataPower catalog source already installed"
fi

wait_for_catalog ibm-datapower-operator-catalog
echo "INFO: Catalog source ibm-datapower-operator-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-eventstreams-catalog) ]]; then
    echo "INFO: Installing IBM Event Streams catalog source"
    if [[ -f ${WORKSPACE_DIR}/event-streams-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/event-streams-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/event-streams-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-eventstreams-catalog
  namespace: openshift-marketplace
spec:
  displayName: "Event Streams from CASE ${ES_CASE_VERSION}"
  image: ${ES_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/event-streams-catalogsource.yaml
else
    echo "INFO: IBM Event Streams catalog source already exists"
fi

wait_for_catalog ibm-eventstreams-catalog
echo "INFO: Catalog source ibm-eventstreams-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-integration-asset-repository-catalog) ]]; then
    echo "INFO: Installing IBM Integration Asset Repository catalog source"
    if [[ -f ${WORKSPACE_DIR}/asset-repo-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/asset-repo-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/asset-repo-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-integration-asset-repository-catalog
  namespace: openshift-marketplace
spec:
  displayName: "Automation Assets from CASE ${AA_CASE_VERSION}"
  image: ${AA_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/asset-repo-catalogsource.yaml
else
    echo "INFO: IBM Integration Asset Repository catalog source already installed"
fi

wait_for_catalog ibm-integration-asset-repository-catalog
echo "INFO: Catalog source ibm-integration-asset-repository-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-integration-operations-dashboard-catalog) ]]; then
    echo "INFO: Installing IBM Integration Operations Dashboard catalog source"
    if [[ -f ${WORKSPACE_DIR}/ops-dashboard-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/ops-dashboard-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/ops-dashboard-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-integration-operations-dashboard-catalog
  namespace: openshift-marketplace
spec:
  displayName: "Operations Dashboard from CASE ${OD_CASE_VERSION}"
  image: ${OD_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/ops-dashboard-catalogsource.yaml
else
    echo "INFO: IBM Integration Operations Dashboard catalog source already installed"
fi

wait_for_catalog ibm-integration-operations-dashboard-catalog
echo "INFO: Catalog source ibm-integration-operations-dashboard-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-integration-platform-navigator-catalog) ]]; then
    echo "INFO: Installing IBM Integration Platform Navigator catalog source"
    if [[ -f platform-navigator-catalogsource.yaml ]]; then rm platform-navigator-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/platform-navigator-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-integration-platform-navigator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "CP4I from CASE ${PN_CASE_VERSION}"
  image: ${PN_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/platform-navigator-catalogsource.yaml
else
    echo "INFO: IBM Integration Platform Navigator catalog source already installed"
fi

wait_for_catalog ibm-integration-platform-navigator-catalog
echo "INFO: Catalog source ibm-integration-platform-navigator-catalog is ready"

if [[ -z $(${BIN_DIR}/oc get catalogsource -n openshift-marketplace | grep ibm-mq-operator-catalog) ]]; then
    echo "INFO: Installing IBM MQ Operator catalog source"
    if [[ -f ${WORKSPACE_DIR}/mq-catalogsource.yaml ]]; then rm ${WORKSPACE_DIR}/mq-catalogsource.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/mq-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-mq-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "MQ from CASE ${MQ_CASE_VERSION}"
  image: ${MQ_CATALOG_IMAGE}
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/mq-catalogsource.yaml
else
    echo "INFO: IBM MQ catalog source already installed"
fi

wait_for_catalog ibm-mq-operator-catalog
echo "INFO: Catalog source ibm-mq-operator-catalog is ready"

#######
# Create operator group if not using cluster scope
if [[ $CLUSTER_SCOPED != "true" ]]; then
    if [[ -z $(${BIN_DIR}/oc get operatorgroups -n ${NAMESPACE} | grep $NAMESPACE-og ) ]]; then
        echo "INFO: Creating operator group for namespace ${NAMESPACE}"
        if [[ -f ${WORKSPACE_DIR}/operator-group.yaml ]]; then rm ${WORKSPACE_DIR}/operator-group.yaml; fi
        cat << EOF >> ${WORKSPACE_DIR}/operator-group.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${NAMESPACE}-og
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
    - ${NAMESPACE}
EOF
    ${BIN_DIR}/oc create -f ${WORKSPACE_DIR}/operator-group.yaml
    else
        echo "INFO: Using existing operator group"
    fi
fi

######
# Create subscriptions

# IBM Common Services operator
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-common-service-operator-ibm-common-service-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Common Services"
    if [[ -f ${WORKSPACE_DIR}/common-services-sub.yaml ]]; then rm ${WORKSPACE_DIR}/common-services-sub.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/common-services-sub.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-common-service-operator-ibm-common-service-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-common-service-operator
  source: ibm-common-service-catalog
  sourceNamespace: openshift-marketplace
  channel: ${CS_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/common-services-sub.yaml
else
    echo "INFO: IBM Common Services subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-common-service-operator-ibm-common-service-catalog-openshift-marketplace 15
echo "INFO: IBM Common Services subscription ready"

# IBM Cloud Redis Databases
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-cloud-databases-redis-operator-ibm-cloud-databases-redis-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Cloud Redis databases"
    if [[ -f ${WORKSPACE_DIR}/ibm-cloud-redis-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/ibm-cloud-redis-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/ibm-cloud-redis-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-cloud-databases-redis-operator-ibm-cloud-databases-redis-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-cloud-databases-redis-operator
  source: ibm-cloud-databases-redis-catalog
  sourceNamespace: openshift-marketplace
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/ibm-cloud-redis-subscription.yaml
else
    echo "INFO: IBM Cloud Redis databases subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-cloud-databases-redis-operator-ibm-cloud-databases-redis-catalog-openshift-marketplace 15
echo "INFO: IBM Cloud Redis databases subscription ready"

# Platform Navigator subscription
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-integration-platform-navigator-ibm-integration-platform-navigator-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Integration Platform Navigator"
    if [[ -f ${WORKSPACE_DIR}/platform-navigator-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/platform-navigator-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/platform-navigator-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-integration-platform-navigator-ibm-integration-platform-navigator-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-integration-platform-navigator
  source: ibm-integration-platform-navigator-catalog
  sourceNamespace: openshift-marketplace
  channel: ${PN_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/platform-navigator-subscription.yaml
else
    echo "INFO: IBM Integration Platform Navigator subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-integration-platform-navigator-ibm-integration-platform-navigator-catalog-openshift-marketplace 15
echo "INFO: IBM Integration Platform Navigator subscription ready"

# Aspera
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep aspera-hsts-operator-ibm-aspera-hsts-operator-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Aspera"
    if [[ -f ${WORKSPACE_DIR}/aspera-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/aspera-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/aspera-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aspera-hsts-operator-ibm-aspera-hsts-operator-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: aspera-hsts-operator
  source: ibm-aspera-hsts-operator-catalog
  sourceNamespace: openshift-marketplace
  channel: ${ASPERA_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/aspera-subscription.yaml
else
    echo "INFO: IBM Aspera subscription already exists"
fi

wait_for_subscription ${NAMESPACE} aspera-hsts-operator-ibm-aspera-hsts-operator-catalog-openshift-marketplace 15
echo "INFO: IBM Aspera subscription ready"

# App Connection
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-appconnect-ibm-appconnect-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM App Connect"
    if [[ -f ${WORKSPACE_DIR}/app-connect-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/app-connect-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/app-connect-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-appconnect-ibm-appconnect-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-appconnect
  source: ibm-appconnect-catalog
  sourceNamespace: openshift-marketplace
  channel: ${APPCONNECT_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/app-connect-subscription.yaml
else
    echo "INFO: IBM App Connect Subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-appconnect-ibm-appconnect-catalog-openshift-marketplace 15
echo "INFO: IBM App Connect subscription ready"

# Eventstreams
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-eventstreams-ibm-eventstreams-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating IBM Event Streams subscription"
    if [[ -f ${WORKSPACE_DIR}/event-streams-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/event-streams-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/event-streams-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-eventstreams-ibm-eventstreams-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-eventstreams
  source: ibm-eventstreams-catalog
  sourceNamespace: openshift-marketplace
  channel: ${ES_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/event-streams-subscription.yaml
else
    echo "INFO: IBM Event Streams subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-eventstreams-ibm-eventstreams-catalog-openshift-marketplace 15
echo "INFO: IBM App Connect subscription ready"

# MQ
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-mq-ibm-mq-operator-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM MQ"
    if [[ -f ${WORKSPACE_DIR}/mq-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/mq-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/mq-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mq-ibm-mq-operator-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-mq
  source: ibm-mq-operator-catalog
  sourceNamespace: openshift-marketplace
  channel: ${MQ_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/mq-subscription.yaml
else
    echo "INFO: IBM MQ subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-mq-ibm-mq-operator-catalog-openshift-marketplace 15
echo "INFO: IBM MQ subscription ready"

# Asset Repo
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-integration-asset-repository-ibm-integration-asset-repository-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Integration Asset Repository"
    if [[ -f ${WORKSPACE_DIR}/asset-repo-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/asset-repo-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/asset-repo-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-integration-asset-repository-ibm-integration-asset-repository-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-integration-asset-repository
  source: ibm-integration-asset-repository-catalog
  sourceNamespace: openshift-marketplace
  channel: ${AA_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/asset-repo-subscription.yaml
else
    echo "INFO: IBM Integration Asset Repository subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-integration-asset-repository-ibm-integration-asset-repository-catalog-openshift-marketplace 15
echo "INFO: IBM Integration Asset Repository subscription ready"

# DataPower
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep datapower-operator-ibm-datapower-operator-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM DataPower"
    if [[ -f ${WORKSPACE_DIR}/data-power-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/data-power-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/data-power-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: datapower-operator-ibm-datapower-operator-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: datapower-operator
  source: ibm-datapower-operator-catalog
  sourceNamespace: openshift-marketplace
  channel: ${DATAPOWER_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/data-power-subscription.yaml
else
    echo "INFO: IBM DataPower subscription already exists"
fi

wait_for_subscription ${NAMESPACE} datapower-operator-ibm-datapower-operator-catalog-openshift-marketplace 15
echo "INFO: IBM DataPower subscription ready"

# API Connect
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-apiconnect-ibm-apiconnect-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM API Connect"
    if [[ -f ${WORKSPACE_DIR}/api-connect-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/api-connect-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/api-connect-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-apiconnect-ibm-apiconnect-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-apiconnect
  source: ibm-apiconnect-catalog
  sourceNamespace: openshift-marketplace
  channel: ${APIC_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/api-connect-subscription.yaml
else
    echo "INFO: IBM API Connect subscription already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-apiconnect-ibm-apiconnect-catalog-openshift-marketplace 15
echo "INFO: IBM API Connect subscription ready"

# Operations Dashboard
if [[ -z $(${BIN_DIR}/oc get subscriptions -n ${NAMESPACE} | grep ibm-integration-operations-dashboard-ibm-integration-operations-dashboard-catalog-openshift-marketplace) ]]; then
    echo "INFO: Creating subscription for IBM Integration Operations Dashboard"
    if [[ -f ${WORKSPACE_DIR}/ops-dashboard-subscription.yaml ]]; then rm ${WORKSPACE_DIR}/ops-dashboard-subscription.yaml; fi
    cat << EOF >> ${WORKSPACE_DIR}/ops-dashboard-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-integration-operations-dashboard-ibm-integration-operations-dashboard-catalog-openshift-marketplace
spec:
  installPlanApproval: Automatic
  name: ibm-integration-operations-dashboard
  source: ibm-integration-operations-dashboard-catalog
  sourceNamespace: openshift-marketplace
  channel: ${OD_OPERATOR_CHANNEL}
EOF
    ${BIN_DIR}/oc create -n ${NAMESPACE} -f ${WORKSPACE_DIR}/ops-dashboard-subscription.yaml
else
    echo "INFO: IBM Integration Operations Dashboard already exists"
fi

wait_for_subscription ${NAMESPACE} ibm-integration-operations-dashboard-ibm-integration-operations-dashboard-catalog-openshift-marketplace 15
echo "INFO: IBM Integration Operations Dashboard ready"

######
# Create platform navigator instance
if [[ $LICENSE == "accept" ]]; then
    if [[ -z $(${BIN_DIR}/oc get PlatformNavigator -n ${INSTANCE_NAMESPACE} | grep ${INSTANCE_NAMESPACE}-navigator ) ]]; then
       echo "INFO: Creating Platform Navigator instance"
        if [[ -f ${WORKSPACE_DIR}/platform-navigator-instance.yaml ]]; then rm ${WORKSPACE_DIR}/platform-navigator-instance.yaml; fi
        cat << EOF >> ${WORKSPACE_DIR}/platform-navigator-instance.yaml
apiVersion: integration.ibm.com/v1beta1
kind: PlatformNavigator
metadata:
  name: ${INSTANCE_NAMESPACE}-navigator
  namespace: ${INSTANCE_NAMESPACE}
spec:
  requestIbmServices:
    licensing: true
  license:
    accept: true
    license: ${LICENSE_ID}
  mqDashboard: true
  replicas: ${REPLICAS}
  version: ${VERSION}
  storage:
    class: ${STORAGE_CLASS}
EOF
        ${BIN_DIR}/oc create -n ${INSTANCE_NAMESPACE} -f ${WORKSPACE_DIR}/platform-navigator-instance.yaml
    else
       echo "INFO: Platform Navigator instance already exists for namespace ${INSTANCE_NAMESPACE}"
    fi

    # Sleep 30 seconds to let navigator get created before checking status
    sleep 30

    count=0
    while [[ $(oc get PlatformNavigator -n ${INSTANCE_NAMESPACE} ${INSTANCE_NAMESPACE}-navigator -o json | jq -r '.status.conditions[] | select(.type=="Ready").status') != "True" ]]; do
       echo "INFO: Waiting for Platform Navigator instance to be ready. Waited $count minutes. Will wait up to 90 minutes."
        sleep 60
        count=$(( $count + 1 ))
        if (( $count > 90)); then    # Timeout set to 90 minutes
           echo "ERROR: Timout waiting for ${INSTANCE_NAMESPACE}-navigator to be ready"
            exit 1
        fi
    done
else
   echo "INFO: License not accepted. Please manually install desired components"
fi

# Store cpi credentials to AWS Secrets Manager (sm)
cpi_username_password_tmp=$(oc extract secret/platform-auth-idp-credentials -n ibm-common-services --to=-)

username=$(echo "$cpi_username_password_tmp" | sed -n '1p')
password=$(echo "$cpi_username_password_tmp" | sed -n '2p')

aws secretsmanager put-secret-value --secret-id "${API_SERVER}-CP4I-Username" --secret-string "$username"
aws secretsmanager put-secret-value --secret-id "${API_SERVER}-CP4I-Password" --secret-string "$password"

# Store cpi url to Secrets Manager (sm)
cpi_url=$(oc get routes cpd -n $INSTANCE_NAMESPACE -o jsonpath='{.spec.host}')
aws secretsmanager put-secret-value --secret-id "${API_SERVER}-CP4I-URL" --secret-string "$cpi_url"