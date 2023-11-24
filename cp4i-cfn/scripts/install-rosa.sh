#!/bin/bash
set -e

### command with all arguments
##### create cluster
### nohup ./rosa.sh --base-path=/home/ec2-user --operation=create --cluster-name=rosa-d01 --compute-machine-type=m5.4xlarge --replicas=3 --region=us-east-2 --machine-cidr=10.0.0.0/16 --service-cidr=172.30.0.0/16 --pod-cidr=10.128.0.0/14 --host-prefix=23 --private=false --multi-az=true --version=4.12.15 --subnets=subnet-5c7d2d610d4db25f,subnet-15bca0698e9b4c41,subnet-3ed7835a97324708,subnet-68bc9661bea107d1,subnet-5a6043f88f7c2461,subnet-a3646c21243f87f9 --fips=false --rosa-token=eyJhbGciOiJIUIqTFJv3GKs9d8k &
##### destroy cluster
### nohup ./rosa.sh --base-path=/home/ec2-user --operation=destroy --cluster-name=rosa-d01 --region=us-east-2 --rosa-token=eyJhbGciOiJIUIqTFJv3GKs9d8k &

# validate command line options
function validate_cmd_options() {

    if [ $operation == "create" ]; then
        # validate compute_machine_type
        if [ -z $compute_machine_type ]; then
            echo "compute_machine_type cannot be blank or empty"
            exit 1;
        fi

        # validate replicas
        if [[ -z $replicas || $replicas -lt 1 ]]; then
            echo "replicas cannot be blank or empty and it must be greater than zero"
            exit 1;
        fi

        # validate machine_cidr
        if [ -z $machine_cidr ]; then
            echo "machine_cidr cannot be blank or empty"
            exit 1;
        fi

        # validate service_cidr
        if [ -z $service_cidr ]; then
            echo "service_cidr cannot be blank or empty"
            exit 1;
        fi

        # validate pod_cidr
        if [ -z $pod_cidr ]; then
            echo "pod_cidr cannot be blank or empty"
            exit 1;
        fi

        # validate host_prefix
        if [ -z $host_prefix ]; then
            echo "host_prefix cannot be blank or empty"
            exit 1;
        fi

        # validate private
        case "$private" in
        "true")
            ;;
        "false")
            ;;
        *)
            echo "The private can either true or false only."
            exit 1;
            ;;
        esac

        # validate multi_az
        case "$multi_az" in
        "true")
            ;;
        "false")
            ;;
        *)
            echo "The multi_az can either true or false only."
            exit 1;
            ;;
        esac

        # validate host_prefix
        if [ -z $version ]; then
            echo "version cannot be blank or empty"
            exit 1;
        fi

        # validate subnets
        if [ -z $subnets ]; then
            echo "subnets cannot be blank or empty"
            echo "Please maintain subents logical orders separated with comma(,). All private subnets first followed by public subents"
            echo "i.e. private-subnet-zone-a,private-subnet-zone-b,private-subnet-zone-c,public-subent-zone-a,public-subent-zone-b,public-subent-zone-c"
            exit 1;
        fi

        # validate fips
        case "$fips" in
        "true")
            ;;
        "false")
            ;;
        *)
            echo "The fips can either true or false only."
            exit 1;
            ;;
        esac

        echo "base_path.."$base_path
        echo "compute_machine_type.."$compute_machine_type
        echo "replicas.."$replicas
        echo "machine_cidr.."$machine_cidr
        echo "service_cidr.."$service_cidr
        echo "pod_cidr.."$pod_cidr
        echo "host_prefix.."$host_prefix
        echo "private.."$private
        echo "multi_az.."$multi_az
        echo "version.."$version
        echo "subnets.."$subnets
        echo "fips.."$fips
    fi

    # validate base_path
    if [ -z $base_path ]; then
        base_path=$(pwd)
    fi

    # validate cluster_name
    if [[ -z $cluster_name || ${#cluster_name} -ge 15 ]]; then
        echo "cluster_name cannot be blank or empty and it must be less than 15 charagets"
        exit 1;
    fi

    # validate region
    if [ -z $region ]; then
        echo "AWS region cannot be blank or empty"
        exit 1;
    fi

    # validate rosa token
    if [ -z $rosa_token ]; then
        echo "rosa-token cannot be blank or empty"
        exit 1;
    fi

    echo "cluster_name.."$cluster_name
    echo "region.."$region
    echo "rosa_token.."$rosa_token
    echo "***** All arguments are validated *****"
}

# identify rosa subnets
function identify_subnets() {
    #split subnets with comma
    subnets_arr=($(echo "$subnets" | tr "," " "))
    # Print the array elements
    # echo ${subnets_arr[0]}
    if [ $private == "true" ]; then
        if [ $multi_az == "true" ]; then
            multi_zone_subnets=${subnets_arr[0]},${subnets_arr[1]},${subnets_arr[2]}
        else
            single_zone_subnets=${subnets_arr[0]}
        fi
    else
        if [ $multi_az == "true" ]; then
            multi_zone_subnets=${subnets_arr[0]},${subnets_arr[1]},${subnets_arr[2]},${subnets_arr[3]},${subnets_arr[4]},${subnets_arr[5]}
        else
            single_zone_subnets=${subnets_arr[0]},${subnets_arr[3]}
        fi
    fi 

    if [ $multi_az == "true" ]; then
        rosa_subnets=$multi_zone_subnets
    else
        rosa_subnets=$single_zone_subnets
    fi
    echo "rosa_subnets.."$rosa_subnets
    echo "***** Subents are identified *****"
}

# download rosa and openshift cli utility
function download_binaries() {
    wget -r -l1 -nd -q $rosa_cli_url -P $installer_workspace
    tar -xvzf $installer_workspace/rosa-linux.tar.gz -C $installer_workspace/
    chmod u+x $installer_workspace/rosa

    wget "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${version}/openshift-client-linux-${version}.tar.gz"
    mv openshift-client-linux-${version}.tar.gz $installer_workspace/openshift-client-linux-${version}.tar.gz
    tar -xvzf $installer_workspace/openshift-client-linux-${version}.tar.gz -C $installer_workspace/
            
    sudo chmod u+x $installer_workspace/oc $installer_workspace/kubectl
    sudo mv $installer_workspace/oc /usr/local/bin
    sudo cp /usr/local/bin/oc /usr/bin/

    sudo mv $installer_workspace/kubectl /usr/local/bin
    sudo cp /usr/local/bin/kubectl /usr/bin/
    echo "***** All binaries are downloaded *****"
}

# create_AWSServiceRoleForElasticLoadBalancing
function create_AWSServiceRoleForElasticLoadBalancing() {
    aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing" || aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"
    echo "***** AWS service role for elastic load balancing is found or created *****"
}

# setup environment
function setup_environment() {
    # rosa subnets
    identify_subnets
    echo "cluster_subnets.."$rosa_subnets

    # download all binaries to installer-files
    download_binaries

    # create AWS service role for elasticloadbalancing
    create_AWSServiceRoleForElasticLoadBalancing
}

# rosa login
function rosa_login() {
    echo "installer_workspace..$installer_workspace"
    echo "rosa_token..$rosa_token"
    $installer_workspace/rosa login --token=$rosa_token
    if [ $? -gt 0 ]; then
        echo "rosa login failed!!"
        exit 1;
    else
        echo "rosa login successfully!!"
    fi
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

# install rosa cluster
function install_rosa_cluster() {
    if [ $private == "true" ]; then
        private_link="--private-link"
    else
        private_link=""
    fi


    version_arr=($(echo "$version" | tr "." " "))
    rosa_major_minor_version=${version_arr[0]}.${version_arr[1]}

    # verify rosa quota
    $installer_workspace/rosa verify quota &&
    ecode=$?
    echo "***** Rosa quota is verified *****"

    # create rosa account IAM roles
    if [ $ecode == 0 ]; then
        $installer_workspace/rosa create account-roles --mode auto --yes --version $rosa_major_minor_version \
        && $installer_workspace/rosa create oidc-config --yes --output json  --mode auto
        ecode=$?
        echo "***** rosa account role is created *****"
    else
        echo "rosa verify quota check is failed"
        exit 1;
    fi

    # install rosa cluster
    if [ $ecode == 0 ]; then
        echo "Triggering cluster creation...."
        $installer_workspace/rosa create cluster $private_link --cluster-name=$cluster_name --compute-machine-type=$compute_machine_type --replicas=$replicas \
         --region=$region --machine-cidr=$machine_cidr --service-cidr=$service_cidr --pod-cidr=$pod_cidr \
         --host-prefix=$host_prefix --private=$private --multi-az=$multi_az --version=$version --subnet-ids=$rosa_subnets \
         --fips=$fips --watch --yes --sts --mode auto && $installer_workspace/rosa logs install --cluster=$cluster_name --watch
        ecode=$?
        echo "***** rosa cluster is created *****"
    else
        echo "Failed to create rosa IAM roles"
        exit 1;
    fi

    if [ $ecode == 0 ]; then
        $installer_workspace/rosa describe cluster --cluster=$cluster_name
        $installer_workspace/rosa create admin --cluster=$cluster_name > $cred_path
        ecode=$?
        echo "***** rosa cluster admin user is created *****"

        # extract login credential
        extract_login_cred

        # oc login
        oc_login

        openshift_url=$(oc get route --all-namespaces | grep console-openshift | awk '{print $3}')
        aws secretsmanager put-secret-value --secret-id "$clustername-OpenshiftURL" --secret-string "https://$openshift_url"

        rosa_api=$(awk '/https/{print $3}' $cred_path)
        aws secretsmanager put-secret-value --secret-id "$clustername-ROSAAPI" --secret-string "$rosa_api"

        rosa_username=$(awk '/https/{print $5}' $cred_path)
        aws secretsmanager put-secret-value --secret-id "$clustername-Openshift-Username" --secret-string "$rosa_username"

        rosa_pwd=$(awk '/https/{print $7}' $cred_path)
        aws secretsmanager put-secret-value --secret-id "$clustername-Openshift-Password" --secret-string "$rosa_pwd"

        rosa_login_command=$(awk '/https/' $cred_path)
        aws secretsmanager put-secret-value --secret-id "$clustername-cluster-login-command" --secret-string "$rosa_login_command"

        echo "***** rosa cluster secrets are stored  *****"
    else
        echo "Failed to create rosa cluster"
    fi

    if [ $ecode != 0 ]; then
        echo "Failed to create admin user"
        exit 1;
    fi
}

# Destroy rosa cluster
function destroy_rosa_cluster() {
    echo "***** Destroying the ROSA clsuter *****"
    echo "installer_workspace..$installer_workspace, cluster_name..$cluster_name"
    cluster_id=$($installer_workspace/rosa describe cluster --cluster=$cluster_name -o json | jq --raw-output .id)
    ecode=$?
    echo "cluster_id.."$cluster_id

    # get cluster id
    if [ $ecode == 0 ]; then
        $installer_workspace/rosa delete cluster --cluster=$cluster_name --yes && $installer_workspace/rosa logs uninstall -c $cluster_name --watch
        echo "***** Cluster is destroyed *****"
        $installer_workspace/rosa delete operator-roles -c $cluster_id --mode auto --yes 
        echo "***** Cluster operator roles are destroyed *****"
        $installer_workspace/rosa delete oidc-provider -c $cluster_id --mode auto --yes 
        echo "***** Cluster OIDC is destroyed *****"
        ecode=$?
        rm -f $cred_path
        rm -f $info_path
    else
        echo "Failed to describe cluster"
    fi 
    echo "***** Destroyed the ROSA clsuter *****"
}

##### script execution is started from below #####

SHORT=bp:,cn:,cmt:,rep:,r:,mc:,sc:,pc:,hp:,p:,maz:,ver:,s:,f:,rt:,op:,h
LONG=base-path:,cluster-name:,compute-machine-type:,replicas:,region:,machine-cidr:,service-cidr:,pod-cidr:,host-prefix:,private:,multi-az:,version:,subnets:,fips:,rosa-token:,operation:,help
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
    -cmt | --compute-machine-type )
      compute_machine_type="$2"
      shift 2
      ;;
    -rep | --replicas )
      replicas="$2"
      shift 2
      ;;
    -r | --region )
      region="$2"
      shift 2
      ;;
    -mc | --machine-cidr )
      machine_cidr="$2"
      shift 2
      ;;
    -sc | --service-cidr )
      service_cidr="$2"
      shift 2
      ;;
    -pc | --pod-cidr )
      pod_cidr="$2"
      shift 2
      ;;
    -hp | --host-prefix )
      host_prefix="$2"
      shift 2
      ;;
    -p | --private )
      private="$2"
      shift 2
      ;;
    -maz | --multi-az )
      multi_az="$2"
      shift 2
      ;;
    -ver | --version )
      version="$2"
      shift 2
      ;;
    -s | --subnets )
      subnets="$2"
      shift 2
      ;;
    -f | --fips )
      fips="$2"
      shift 2
      ;;
    -rt | --rosa-token )
      rosa_token="$2"
      shift 2
      ;;
    -op | --operation )
      operation="$2"
      shift 2
      ;;

    -h | --help)
      "This is a install rosa script"
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

# create installer files
mkdir -p $base_path/installer-files

export installer_workspace=$base_path/installer-files
export cred_path=$installer_workspace/.cred
export info_path=$installer_workspace/.info
export rosa_cli_url=https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz

# install rosa cluster
case "$operation" in
"create")
    setup_environment
    # rosa login
    rosa_login

    install_rosa_cluster
    ;;
"destroy")
    # rosa login
    rosa_login
    destroy_rosa_cluster
    ;;
*)
    echo "The operation can either create or destroy only"
    exit 1;
    ;;
esac
