#!/bin/bash

set -Ee -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="argocd-demo"
declare USER=""
declare PASSWORD=""
declare slack_webhook_url=""
declare INSTALL_PREREQ=""
declare ARGO_OPERATOR_PRJ="argocd"

display_usage() {
cat << EOF
$0: Create GitOps (ArgoCD) Demo --

  Usage: ${0##*/} [ OPTIONS ]
  
    -i         [optional] Install prerequisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to "argocd-demo"

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
  while getopts ':ip:h' option; do
      case "${option}" in
          i  ) prereq_flag=true;;
          p  ) p_flag=true; PRJ_PREFIX="${OPTARG}";;
          a  ) a_flag=true; ARGO_OPERATOR_PRJ="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${PRJ_PREFIX}" ]]; then
      printf '%s\n\n' 'ERROR - PRJ_PREFIX must not be null' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${ARGO_OPERATOR_PRJ}" ]]; then
      printf '%s\n\n' 'ERROR - ARGO_OPERATOR_PRJ must not be null' >&2
      display_usage >&2
      exit 1
  fi
}

main() {
    # import common functions
  . $SCRIPT_DIR/common-func.sh

  trap 'error' ERR
  trap 'cleanup' EXIT SIGTERM
  trap 'interrupt' SIGINT

  oc version >/dev/null 2>&1 || error "no oc binary found"

  if [[ -z "${DEMO_HOME:-}" ]]; then
    error 'DEMO_HOME not set'
  fi

  get_and_validate_options "$@"

  declare -r dev_prj="$PRJ_PREFIX-dev"
  declare -r stage_prj="$PRJ_PREFIX-stage"
  declare -r cicd_prj="$PRJ_PREFIX-cicd"
  declare -r sup_prj="$PRJ_PREFIX-support"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns $cicd_prj 2>/dev/null  || { 
    oc new-project $cicd_prj 
  }
  oc get ns $dev_prj 2>/dev/null  || { 
    oc new-project $dev_prj
  }
  oc get ns $stage_prj 2>/dev/null  || { 
    oc new-project $stage_prj 
  }

  if [[ -n "${prereq_flag:-}" ]]; then
    $SCRIPT_DIR/install-prereq.sh -a ${ARGO_OPERATOR_PRJ} -s $sup_prj -k
  fi

  # info "Create pull secret for redhat registry"
  # $DEMO_HOME/scripts/util-create-pull-secret.sh registry-redhat-io --project $cicd_prj -u $USER -p $PASSWORD

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -R -f $DEMO_HOME/kube/cd -n $cicd_prj

    # There can be a race when the system is installing the pipeline operator in the $cicd_prj
  echo -n "Waiting for Pipelines Operator to be installed in $cicd_prj..."
  while [[ "$(oc get $(oc get csv -oname -n $cicd_prj| grep pipelines) -o jsonpath='{.status.phase}' -n $cicd_prj 2>/dev/null)" != "Succeeded" ]]; do
      echo -n "."
      sleep 1
  done

  info "Configure service account permissions for pipeline"
  # Add a cluster role that allows fined grained access to knative resources without granting edit
  oc apply -f $DEMO_HOME/kube/tekton/roles
  # ..and assign the pipeline service account that role in the dev project
  oc adm policy add-cluster-role-to-user -n $dev_prj kn-deployer system:serviceaccount:$cicd_prj:pipeline
  oc adm policy add-cluster-role-to-user -n $cicd_prj ns-creator -z pipeline

  # FIXME: Change to allow all serviceaccounts to pull from the cicd project
  # oc adm policy add-role-to-group system:image-puller system:serviceaccounts -n ${cicd_prj}
  oc adm policy add-role-to-group system:image-puller system:authenticated -n ${cicd_prj}

  info "Setting image-puller permissions for other projecct service accounts into $cicd_prj"
  arrPrjs=( ${dev_prj} ${stage_prj} )
  arrSAs=( default pipeline builder )
  for prj in "${arrPrjs[@]}"; do
    for sa in "${arrSAs[@]}"; do
      oc adm policy add-role-to-user system:image-puller system:serviceaccount:${prj}:${sa} -n ${cicd_prj}
    done
  done
  
  info "Deploying pipeline and tasks to $cicd_prj namespace"
  oc apply -f $DEMO_HOME/kube/tekton/tasks --recursive -n $cicd_prj
  oc apply -R -f $DEMO_HOME/kube/tekton/config -n $cicd_prj
  oc apply -R -f $DEMO_HOME/kube/tekton/init/tasks -n $cicd_prj

  info "Creating workspaces volumes in $cicd_prj namespace"
  oc apply -R -f $DEMO_HOME/kube/tekton/workspaces -n $cicd_prj
  
  # if [[ -z "${slack_webhook_url}" ]]; then
  #   info "NOTE: No slack webhook url is set.  You can add this later by running oc create secret generic slack-webhook-secret."
  # else
  #   oc delete secret slack-webhook-secret -n $cicd_prj || true
  #   oc create secret generic slack-webhook-secret --from-literal=url=${slack_webhook_url} -n $cicd_prj
  # fi

  # info "Deploying dev and staging pipelines"
  # if [[ -z "$SKIP_STAGING_PIPELINE" ]]; then
  #   oc process -f $DEMO_HOME/kube/tekton/pipelines/petclinic-stage-pipeline-tomcat-template.yaml -p PROJECT_NAME=$cicd_prj \
  #     -p DEVELOPMENT_PROJECT=$dev_prj -p STAGING_PROJECT=$stage_prj -p CICD_PROJECT=$cicd_prj | oc apply -f - -n $cicd_prj
  # else
  #   info "Skipping deploy to staging pipeline at user's request"
  # fi
  sed "s/demo-dev/$dev_prj/g" $DEMO_HOME/kube/tekton/pipelines/payment-pipeline.yaml | sed "s/demo-support/$sup_prj/g" | oc apply -f - -n $cicd_prj
  sed "s/demo-cicd/$cicd_prj/g" $DEMO_HOME/kube/tekton/pipelines/promote-payment-pipeline.yaml | oc apply -f - -n $cicd_prj
  # Install pipeline resources
  sed "s/demo-cicd/$cicd_prj/g" $DEMO_HOME/kube/tekton/resources/payment-image.yaml | oc apply -f - -n $cicd_prj
  
  # FIXME: Decide which repo we want to trigger/pull from
  # sed "s#https://github.com/spring-projects/spring-petclinic#http://$GOGS_HOSTNAME/gogs/spring-petclinic.git#g" $DEMO_HOME/kube/tekton/resources/petclinic-git.yaml | oc apply -f - -n $cicd_prj
 
  # Install pipeline triggers
  oc apply -f $DEMO_HOME/kube/tekton/triggers --recursive -n $cicd_prj

  info "Initiatlizing git repository in gitea and configuring webhooks"
  oc apply -f $DEMO_HOME/kube/gitea/gitea-server-cr.yaml -n $cicd_prj
  oc wait --for=condition=Running Gitea/gitea-server -n $cicd_prj --timeout=6m
  echo -n "Waiting for gitea deployment to appear..."
  while [[ -z "$(oc get deploy gitea -n $cicd_prj 2>/dev/null)" ]]; do
    echo -n "."
    sleep 1
  done
  echo "done!"
  oc rollout status deploy/gitea -n $cicd_prj

  # patch the created gitea service to select the proper pod
 # oc patch svc/gitea -p '{"spec":{"selector":{"app":"gitea"}}}' -n $cicd_prj

  oc create -f $DEMO_HOME/kube/gitea/gitea-init-taskrun.yaml -n $cicd_prj
  # output the logs of the latest task
  tkn tr logs -L -f -n $cicd_prj

  info "Configure nexus repo"
  $SCRIPT_DIR/util-config-nexus.sh -n $cicd_prj -u admin -p admin123

  info "Seed maven cache in workspace"
  oc create -n $cicd_prj -f $DEMO_HOME/kube/tekton/init/seed-cache-task-run.yaml
  tkn tr logs -L -f -n $cicd_prj

  #
  # Configure ArgoCD
  # 
  echo "Configuring ArgoCD for targeting project $stage_prj"
  argocd_pwd=$(oc get secret argocd-cluster -n ${ARGO_OPERATOR_PRJ} -o jsonpath='{.data.admin\.password}' | base64 -d)
  argocd_url=$(oc get route argocd-server -n ${ARGO_OPERATOR_PRJ} -o template --template='{{.spec.host}}')
  argocd login $argocd_url --username admin --password $argocd_pwd --insecure

  echo "Creating argo configmaps and secrets based on current deployment"
  cat <<EOF | oc apply -n $cicd_prj -f -
apiVersion: operators.coreos.com/v1alpha1
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-env-configmap
data:
  ARGOCD_SERVER: argocd-server.${ARGO_OPERATOR_PRJ}.svc.cluster.local
  ARGOCD_EXTERNAL_HOSTNAME: ${argocd_url}
EOF

  cat << EOF | oc apply -n $cicd_prj -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-env-secret
stringData:
  # choose one of username/password or auth token
  ARGOCD_USERNAME: admin
  ARGOCD_PASSWORD: ${argocd_pwd}
EOF

  # FIXME: Shouldn't this line be codified in the gitops repo?  This might be necessary for bootstrapping, but after that...
  oc policy add-role-to-user edit system:serviceaccount:${ARGO_OPERATOR_PRJ}:argocd-application-controller -n $stage_prj

  # Create an initial deployment of the app into the staging environment
  # NOTE: can't use directory-recurse with Kustomize based deployment or you'll get an error (as it tries to deploy Kustomize itself)
  # See here for more info: https://github.com/argoproj/argo-cd/issues/3181
  argocd app create coolstore-argo --repo http://gitea.$cicd_prj:3000/gogs/coolstore-gitops --path kube --dest-namespace $stage_prj --dest-server https://kubernetes.default.svc \
    --directory-recurse=false --revision master --sync-policy automated --self-heal --auto-prune
  
  # NOTE: it's setup to autosync so this is not necessary
  # argocd app sync petclinic-argo

  echo -e "\nArgoCD URL: $argocd_url\nUser: admin\nPassword: $argocd_pwd"

  # Leave user in cicd project
  oc project $cicd_prj

  cat <<-EOF
#####################################
Installation finished successfully!
#####################################
EOF
}


main $@