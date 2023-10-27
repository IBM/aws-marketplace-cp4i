#!/bin/bash

### command with all arguments
##### configure NFS storage
### ./setup-efs.sh --base-path=/home/ec2-user --operation=create --subnets=subnet-5c7d2d610d4db25f,subnet-15bca0698e9b4c41,subnet-3ed7835a97324708
##### destroy NFS storage
### ./setup-efs.sh --base-path=/home/ec2-user --operation=destroy


# validate cmd options
function validate_cmd_options() {
    if [[ $operation == "create" ]]; then
        
        # validate subnets
        if [ -z $subnets ]; then
            echo "subnets cannot be blank or empty"
            echo "Please maintain subents logical orders with separated comma(,). All private subnets first followed by public subents"
            echo "i.e. private-subnet-zone-a,private-subnet-zone-b,private-subnet-zone-c,public-subent-zone-a,public-subent-zone-b,public-subent-zone-c"
            exit 1;
        fi

        # validate cluster_url
        if [ -z $cluster_url ]; then
            echo "cluster-url is blank or empty. So, it'll be refer from .cred file"
        fi

        # validate cluster_url
        if [ -z $cluster_username ]; then
            echo "cluster-username is blank or empty. So, it'll be refer from .cred file"
        fi

        # validate cluster_url
        if [ -z $cluster_password ]; then
            echo "cluster-password is blank or empty. So, it'll be refer from .cred file"
        fi

        # validate region
        if [ -z $region ]; then
            echo "region is blank or empty. So, it'll be refer from ec2 metadata"
        fi
    fi

    # validate base_path
    if [ -z $base_path ]; then
        base_path=$(pwd)
    fi

    # validate info_path
    if [ -z $info_path ]; then
        echo ".info file path is blank or empty. So, it'll try to retrieve from default path"
        info_path=$default_info_path
    fi

    # validate info_path
    if [ -z $cred_path ]; then
        echo ".cred file path is blank or empty. So, it'll try to retrieve from default path"
        cred_path=$default_cred_path
    fi

    if [[ -f "$cred_path" ]]; then
      echo "$cred_path exists."
    else
      echo ".cred file is missing."
    fi

    echo "***** All arguments are validated *****"
}

# download cpd-cli utility
function download_binaries() {
    # install podman
    sudo yum install -y podman jq gettext

    # download cpd-cli
    wget -r -l1 -nd -q $cpd_cli_url -P $installer_workspace
    tar -xvzf $installer_workspace/cpd-cli-linux-SE-$cpd_cli_version.tgz -C $installer_workspace/
    sudo cp -r $installer_workspace/cpd-cli-linux-SE-13.0.3-40/* /usr/local/bin/
    sudo cp -r $installer_workspace/cpd-cli-linux-SE-13.0.3-40/* /usr/bin/
    echo $(cpd-cli version)

    echo "***** All require binaries are downloaded *****"
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

# cpd-cli-login
function cpd_cli_login() {
  echo "cluster_username..$cluster_username, cluster_password..$cluster_password, cluster_url..$cluster_url"
  cpd-cli manage login-to-ocp --username=$cluster_username --password=$cluster_password --server=$cluster_url
  echo "***** cpd-cli login is successful *****"
}

# authorize_security_group_ingress for EFS port
function authorize_security_group_ingress() {
    worker_node=$(oc get nodes --selector=node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
    vpc_id=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$worker_node" --query 'Reservations[*].Instances[*].{VpcId:VpcId}' | jq -r '.[0][0].VpcId')
    vpc_cidr=$(aws ec2 describe-vpcs --filters "Name=vpc-id,Values=$vpc_id" --query 'Vpcs[*].CidrBlock' | jq -r '.[0]')
    sg_id=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$worker_node" --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' | jq -r '.[0][0].SecurityGroups[0].GroupId')

    aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 2049 --cidr $vpc_cidr | jq . || true
    echo "***** authorize_security_group_ingress is completed *****"   
}

# create EFS
function create_efs() {
    cluster_name=$(echo "$cluster_url" | sed -e 's|https://api\.\([^\.]*\).*|\1|')

    filesystem_id=$(aws efs create-file-system --performance-mode \
      generalPurpose --encrypted \
      --region ${region} \
      --tags Key=Name,Value=${cluster_name}-elastic | jq -r '.FileSystemId')
    echo "efs_filesystem_id "$filesystem_id >> $info_path
    echo "***** EFS filesystem $filesystem_id is created *****"
    sleep 10

    # create mount point
    create_efs_mountpoints
}

# create EFS mountpoint
function create_efs_mountpoints() {
    echo "efs_mountpoint_subnets..$subnets"
    IFS=, read -ra subents_arr <<< "$subnets"
    mnt=""
    for sa in ${subents_arr[@]}; do 
        m=$(aws efs create-mount-target --file-system-id $filesystem_id --subnet-id $sa --security-groups $sg_id | jq --raw-output .MountTargetId)
        mnt=$mnt$m","
    done
    mnt="${mnt%,}"
    echo "efs_mount_points "$mnt >> $info_path
    echo "***** EFS mountpoints are created *****"
    sleep 300
}

#configure nfs
function setup_nfs() {
  efs_location=$filesystem_id.efs.$region.amazonaws.com
  efs_path=/
  namespace=nfs-provisioner
  efs_storage_class=efs-nfs-client
  nfs_image=k8s.gcr.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2

  cpd-cli manage setup-nfs-provisioner --nfs_server=$efs_location \
    --nfs_path=$efs_path \
    --nfs_provisioner_ns=$namespace \
    --nfs_storageclass_name=$efs_storage_class \
    --nfs_provisioner_image=$nfs_image
  
  status="unknown"
  while [ "$status" != "Running" ]
  do
    pod_name=$(oc get pods -n $namespace | grep nfs-client | awk '{print $1}' )
    ready_status=$(oc get pods -n $namespace $pod_name  --no-headers | awk '{print $2}')
    pod_status=$(oc get pods -n $namespace $pod_name --no-headers | awk '{print $3}')
    echo $pod_name State - $ready_status, podstatus - $pod_status
    if [ "$ready_status" == "1/1" ] && [ "$pod_status" == "Running" ]
    then
    status="Running"
    else
    status="starting"
    sleep 10
    fi
    echo "$pod_name is $status"
  done
}

# destroy EFS
function destroy_efs() {
  echo "***** Destroying EFS storage *****"
  storage=$(cat "$info_path" | grep -oE -- 'storage ([^ ]+)' | cut -d' ' -f2)
  efs_filesystem_id=$(cat "$info_path" | grep -oE -- 'efs_filesystem_id ([^ ]+)' | cut -d' ' -f2)
  efs_mount_points=$(cat "$info_path" | grep -oE -- 'efs_mount_points ([^ ]+)' | cut -d' ' -f2)
  echo "storage..$storage, efs_filesystem_id..$efs_filesystem_id, efs_mount_points..$efs_mount_points"

  IFS=, read -ra emp_arr <<< "$efs_mount_points"
  for e in ${emp_arr[@]}; do 
    aws efs delete-mount-target --mount-target-id $e || true
  done
  sleep 60
  aws efs delete-file-system --file-system-id $efs_filesystem_id
  echo "efs file system $efs_filesystem_id is destroyed"
  echo "***** Destroyed EFS storage *****"
} 

# load balancing IAM service link role
function create_service_link_role() {
  aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing" || aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"
  echo "***** create_service_link_role is completed *****"
}


##### script execution is started from below #####

SHORT=bp:,s:,curl:,cuser:,cpass:,op:,ip:,r:,h
LONG=base-path:,subnets:,cluster-url:,cluster-username:,cluster-password:,operation:,info-path:,region:,help
OPTS=$(getopt -a -n weather --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    -bp | --base-path )
      base_path="$2"
      shift 2
      ;;
    -ip | --info-path )
      info_path="$2"
      shift 2
      ;;
    -s | --subnets )
      subnets="$2"
      shift 2
      ;;
    -r | --region )
      region="$2"
      shift 2
      ;;
    -curl | --cluster-url )
      cluster_url="$2"
      shift 2
      ;;
    -cuser | --cluster-username )
      cluster_username="$2"
      shift 2
      ;;
    -cpass | --cluster-password )
      cluster_password="$2"
      shift 2
      ;;
    -op | --operation )
      operation="$2"
      shift 2
      ;;

    -h | --help)
      "This is a setup efs script"
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
export cpd_cli_version=13.0.3
export cpd_cli_url=https://github.com/IBM/cpd-cli/releases/download/v$cpd_cli_version/cpd-cli-linux-SE-$cpd_cli_version.tgz

validate_cmd_options
echo "***** all NFS cmd options validation is completed *****"

extract_login_cred

# oc login
oc_login

if [ $operation == "destroy" ]; then
  destroy_efs

elif [ $operation == "create" ]; then
  #download binaries
  download_binaries

  #cpd-cli login
  cpd_cli_login

  # create service link role
  create_service_link_role

  # authorize sg 
  authorize_security_group_ingress

  # create efs
  create_efs

  # setup NFS provisioner
  setup_nfs
else
  echo "Invalid efs storage operation" $operation
fi