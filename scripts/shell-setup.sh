#!/bin/bash
declare SCRIPT=$0
if [[ "$SCRIPT" == "/bin/bash" ]]; then
    SCRIPT="${BASH_SOURCE}"
fi

if [[ -z "${SCRIPT}" ]]; then
    echo "BASH_SOURCE: ${BASH_SOURCE}, 0 is: $0"
    echo "Failed to find the running name of the script, you need to set DEMO_HOME manually"
fi

export DEMO_HOME=$( cd "$(dirname "${SCRIPT}")/.." ; pwd -P )

alias cpr='tkn pr cancel $(tkn pr list -o name --limit 1 | cut -f 2 -d "/")'
alias ctr='tkn tr cancel $(tkn tr list -o name --limit 1 | cut -f 2 -d "/")'

# shorthand for creating a pipeline run file and watching the logs
pr () {
    FILE="$1"
    PRJ="${2:-argocd-demo-cicd}"
    oc create -f $FILE -n $PRJ
    tkn pr logs -L -f -n $PRJ
}

tskr () {
    FILE="$1"
    oc create -f $FILE && tkn tr logs -L -f
}

aws-up() {
    local CLUSTER_NAME=${1:-${CLUSTERNAME}}
    if [[ -z "${CLUSTER_NAME}" ]]; then
        echo "Must provide a cluster name either as parameter or in environment variable `CLUSTERNAME`"
        return 1
    fi

    local AWS_REGION=${REGION}
    if [[ -z "${AWS_REGION}" ]]; then
        echo "Must provide a region by way of REGION environment variable"
        return 1
    fi

    aws ec2 start-instances --instance-ids --region=${AWS_REGION} \
        $(aws ec2 describe-instances --region ${AWS_REGION} --query 'Reservations[*].Instances[*].{Instance:InstanceId}' --output text --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}-*" "Name=instance-state-name,Values=stopped")
}

aws-down() {
    local CLUSTER_NAME=${1:-${CLUSTERNAME}}
    if [[ -z "$CLUSTER_NAME" ]]; then
        echo "Must provide a cluster name either as parameter or in environment variable `CLUSTERNAME`"
        return 1
    fi

    local AWS_REGION=${REGION}
    if [[ -z "${AWS_REGION}" ]]; then
        echo "Must provide a region by way of REGION environment variable"
        return 1
    fi

    aws ec2 stop-instances --instance-ids --region ${AWS_REGION} \
        $(aws ec2 describe-instances --region ${AWS_REGION} --query 'Reservations[*].Instances[*].{Instance:InstanceId}' --output text --filters "Name=tag-key,Values=kubernetes.io/cluster/${CLUSTER_NAME}-*" "Name=instance-state-name,Values=running") 
}

rosa-helper() {
    local EC2_COMMAND=$1
    local ROSA_NAME=${2:-${ROSA_CLUSTER_NAME}}
    if [[ -z "$ROSA_NAME" ]]; then
        echo "Must provide a rosa cluster id (e.g. mwh-test) either as parameter or in environment variable ROSA_CLUSTER_NAME"
        echo "Available rosa clusters: $(rosa list clusters -o json | jq -r '.[0].name')"
        return 1
    fi

    aws ec2 "${EC2_COMMAND}" --instance-ids \
        $(aws ec2 describe-instances --filters Name="tag-key",Values="kubernetes.io/cluster/${ROSA_NAME}-*" --query 'Reservations[*].Instances[*].{Instance:InstanceId}' --output text)
}

rosa-up() {
    rosa-helper "start-instances" $1
}

rosa-down() {
    rosa-helper "stop-instances" $1
}