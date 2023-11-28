#!/bin/bash

function validate_cmd_options() {

    # validate base_path
    if [ -z $base_path ]; then
        base_path=$(pwd)
    fi

    echo "base_path.."$base_path
    echo "***** All arguments are validated *****"
}

# extract_login_cred
function extract_login_cred() {
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
ocloginmaxcounter=5
oclogincounter=0
ocloginfailed=false
function oc_login() {
    echo "oc login $cluster_url --username=$cluster_username --password=$cluster_password --insecure-skip-tls-verify"
    oc login $cluster_url --username=$cluster_username --password=$cluster_password --insecure-skip-tls-verify

    if [ $? == 0 ]; then
        echo "***** OC login is successful *****"
        ocloginfailed=false
    else
      while [ $oclogincounter -lt $oclogincounter ];
      do
          echo "oc login failed..!!$oclogincounter"
          sleep 30
          oc_login
          ocloginfailed=true
          ((oclogincounter++))
      done
    fi
   
    echo "ocloginfailed..$ocloginfailed"
    if $ocloginfailed; then
      echo "***** OC login is failed after $ocloginmaxcounter attempt *****"
      exit 1;
    fi
}


SHORT=bp:,cn:,in:,h
LONG=base-path:,cluster-name:,instance-namespace:,help
OPTS=$(getopt -a -n weather --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    -bp | --base-path )
      base_path="$2"
      shift 2
      ;;
    -cn | --cluster-name )
      cluster_name="$2"
      shift 2
      ;;
    -in | --instance-namespace )
      instance_namespace="$2"
      shift 2
      ;;


    -h | --help)
      "This is a store-secrets script"
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

validate_cmd_options

export installer_workspace=$base_path/installer-files
export cred_path=$installer_workspace/.cred

# extract login credential
extract_login_cred

# oc login
oc_login

clustername=$cluster_name

openshift_url=$(oc get route --all-namespaces | grep console-openshift | awk '{print $3}')
aws secretsmanager put-secret-value --secret-id "$clustername-OpenshiftURL" --secret-string "$openshift_url"

rosa_api=$(awk '/https/{print $3}' $cred_path)
aws secretsmanager put-secret-value --secret-id "$clustername-ROSAAPI" --secret-string \"$rosa_api\"

rosa_username=$(awk '/https/{print $5}' $cred_path)
aws secretsmanager put-secret-value --secret-id "$clustername-Openshift-Username" --secret-string "$rosa_username"

rosa_pwd=$(awk '/https/{print $7}' $cred_path)
aws secretsmanager put-secret-value --secret-id "$clustername-Openshift-Password" --secret-string "$rosa_pwd"

rosa_login_command=$(awk '/https/' $cred_path)
aws secretsmanager put-secret-value --secret-id "$clustername-cluster-login-command" --secret-string "$rosa_login_command"

echo "***** rosa cluster secrets are stored  *****"

# Store cpi credentials to AWS Secrets Manager (sm)
cpi_username_password_tmp=$(oc extract secret/platform-auth-idp-credentials -n ibm-common-services --to=-)

username=$(oc get secret platform-auth-idp-credentials   -n ibm-common-services -o jsonpath='{.data.admin_username}'   | base64 -d)
password=$(oc get secret platform-auth-idp-credentials   -n ibm-common-services -o jsonpath='{.data.admin_password}'   | base64 -d)

aws secretsmanager put-secret-value --secret-id "$clustername-CP4I-Username" --secret-string "$username"
aws secretsmanager put-secret-value --secret-id "$clustername-CP4I-Password" --secret-string "$password"

# Store cpi url to Secrets Manager (sm)
cpi_url=$(oc get routes cpd -n $instance_namespace -o jsonpath='{.spec.host}')
aws secretsmanager put-secret-value --secret-id "$clustername-CP4I-URL" --secret-string "$cpi_url"
echo "***** CP4I secrets are stored  *****"