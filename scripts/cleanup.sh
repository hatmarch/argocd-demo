#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="argocd-demo"
declare ARGO_APP="coolstore-argo"

# project where the argo operator is installed (and where the argo server is running in cluster)
declare ARGO_PROJECT="argocd"

display_usage() {
cat << EOF
$0: GitOps (Argo) Demo Uninstall --

  Usage: ${0##*/} [ OPTIONS ]
  
    -f         [optional] Full uninstall, removing pre-requisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to argo-demo
EOF
}

get_and_validate_options() {
  # Transform long options to short ones
    #   for arg in "$@"; do
    #     shift
    #     case "$arg" in
    #       "--long-x") set -- "$@" "-x" ;;
    #       "--long-y") set -- "$@" "-y" ;;
    #       *)        set -- "$@" "$arg"
    #     esac
    #   done

    
    # parse options
    while getopts ':p:fh' option; do
        case "${option}" in
            p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
            f  ) full_flag=true;;
            h  ) display_usage; exit;;
            \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
            :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"

    if [[ -z "${PROJECT_PREFIX}" ]]; then
        printf '%s\n\n' 'ERROR - PROJECT_PREFIX must not be null' >&2
        display_usage >&2
        exit 1
    fi
}


remove-operator()
{
    OPERATOR_NAME=$1
    OPERATOR_PRJ=${2:-openshift-operators}

    echo "Uninstalling operator: ${OPERATOR_NAME} from project ${OPERATOR_PRJ}"
    # NOTE: there is intentionally a space before "currentCSV" in the grep since without it f.currentCSV will also be matched which is not what we want
    CURRENT_CSV=$(oc get sub ${OPERATOR_NAME} -n ${OPERATOR_PRJ} -o yaml | grep " currentCSV:" | sed "s/.*currentCSV: //")
    oc delete sub ${OPERATOR_NAME} -n ${OPERATOR_PRJ} || true
    oc delete csv ${CURRENT_CSV} -n ${OPERATOR_PRJ} || true

    # Attempt to remove any orphaned install plan named for the csv
    oc get installplan -n ${OPERATOR_PRJ} | grep ${CURRENT_CSV} | awk '{print $1}' 2>/dev/null | xargs oc delete installplan -n $OPERATOR_PRJ
}

remove-crds() 
{
    API_NAME=$1

    oc get crd -oname | grep "${API_NAME}" | xargs oc delete
}

main() 
{
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    if [[ -n "$(oc get project ${ARGO_PROJECT} 2>/dev/null)" ]]; then
        argocd_pwd=$(oc get secret argocd-cluster -n ${ARGO_PROJECT} -o jsonpath='{.data.admin\.password}' | base64 -d)
        argocd_url=$(oc get route argocd-server -n ${ARGO_PROJECT} -o template --template='{{.spec.host}}')
        argocd login $argocd_url --username admin --password $argocd_pwd --insecure

        # delete argocd integration
        echo "Deleting argocd integration app ${ARGO_APP}"
        argocd app delete ${ARGO_APP} --cascade=false || true
    fi

 
    if [[ -n "${full_flag:-}" ]]; then
        echo "Removing Gitea Operator"
        oc delete project gpte-operators || true
        oc delete clusterrole gitea-operator || true
        remove-crds gitea || true

        remove-operator argocd-operator argocd || true

        echo "Deleting any remaining argocd applications before deleting namespace and CRDs"
        oc delete application --all -n argocd || true

        oc delete project argocd || true

        remove-crds argo || true

        echo "Uninstalling knative eventing"
        oc delete knativeeventings.operator.knative.dev knative-eventing -n knative-eventing || true
        oc delete namespace knative-eventing || true

        echo "Uninstalling knative serving"
        oc delete knativeservings.operator.knative.dev knative-serving -n knative-serving || true
        # note, it takes a while to remove the namespace.  Move on to other things before we wait for the removal
        # of this project below
        oc delete namespace knative-serving --wait=false || true

        # uninstall operators without special removal requirements
        declare OTHER_OPERATORS=( openshift-pipelines-operator-rh amq-streams knative-kafka-operator )
        for OPERATOR in "${OTHER_OPERATORS[@]}"; do
            remove-operator ${OPERATOR} || true
        done

        # actually wait for knative-serving to finish being deleted before we remove the operator
        oc delete namespace knative-serving || true
        remove-operator "serverless-operator" || true
    fi

    # declare an array
    arrSuffix=( "dev" "stage" "cicd")
    
    # for loop that iterates over each element in arr
    for i in "${arrSuffix[@]}"
    do
        echo "Deleting $i"
        oc delete project "${PROJECT_PREFIX}-${i}" || true
    done

    if [[ -n "${full_flag:-}" ]]; then
        echo "Removing support project"
        oc delete project "${PROJECT_PREFIX}-support" || true

        echo "Cleaning up CRDs"

        # delete all CRDS that maybe have been left over from operators
        CRDS=( "kafka.strimzi.io" "knative.dev" "tekton.dev" )
        for CRD in "${CRDS[@]}"; do
            remove-crds ${CRD} || true
        done
    fi

    echo "Cleanup finished successfully"
}

main "$@"