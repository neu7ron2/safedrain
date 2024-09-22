#!/bin/bash
## This script aims to safely drain a node especially where you have a
## single pod deployment which need to be restarted on another node first.
## This script is an alternative to `kubectl drain NODE`
## The current Kubernets drain operation has a limitation in that it first
## terminate pods before starting new ones. This script will ensure the
## pods are rolled out on another node before terminating them.
## Any deployment/statefulset should have a rollout strategy defined in the 
## manifest similar to below:
##
##       strategy:
##         type: RollingUpdate
##         rollingUpdate:
##           maxSurge: 1
##           maxUnavailable: 0
##
set -e
NODE_NAME=$1


if [[ "$NODE_NAME" == "" ]]; then
  echo "
  USAGE: ./safedrain.sh <NODE_NAME>

  Safely drain a Kubernetes node by forcing a rollout restart
  on all Deployments and StatefulSets that have pods running on
  that node. Wrapper for command 'kubectl drain'

  Examples:
    ./safedrain.sh NODE_NAME [options]"
  exit 1
fi


function rollout() {
  IFS=$'\n'
  ## Deployment or StatefulSet.
  DEPTYPE=$1

  ## Loop through all deployments or statefulsets in the cluster
  for DEPLOY_ITEM in $(kubectl get $DEPTYPE -A -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{.spec.selector.matchLabels}{"\n"}{end}'); do
   
   ## Get the Selector labels for the pods
   IFS=!' '
   read DEPLOY_NAME NAMESPACE LABELS <<< $DEPLOY_ITEM
   LABELS=$(echo $LABELS | sed 's/:/=/g; s/[{}"]//g')

   ## Get all the Pods on the specific node that belong to the Deployment/statefulSet
   echo "Checking $DEPTYPE name= $DEPLOY_NAME"
   PODLIST=$(kubectl get pods -n $NAMESPACE -l $LABELS --field-selector spec.nodeName=$NODE_NAME -o=jsonpath='{range .items[*]}{.metadata.name}')

    if [ "$PODLIST" != "" ]; then
       ## Get a list of all the Pods across all the node to check if there are multiple on other nodes we can ignore doing a rollout
       PODLIST_ALL_NODES=$(kubectl get pods -n $NAMESPACE -l $LABELS -o=jsonpath='{range .items[*]}{.metadata.name}')
       if [ "$PODLIST"  != "$PODLIST_ALL_NODES" ]; then
          echo "A pod $PODLIST was found with replicas on other nodes. Multi node replicas can be ignored for a re-rollout"
       else
                read -p "A pod belonging to deployment $DEPLOY_NAME was found on $NODE_NAME, press any key to rollout the deployment on another node?" confirm 
                echo $(kubectl rollout restart -n $NAMESPACE $DEPTYPE $DEPLOY_NAME)

                ## Keep looping until the pod a been terminated from the node
               echo "Wait for pod to move to terminate state...(this could take a while)...if it never terminates then you should look why the pod can't be deleted"                
               while [ "$(kubectl get pods --no-headers -n $NAMESPACE -l $LABELS --field-selector spec.nodeName=$NODE_NAME -o=jsonpath='{range .items[*]}{.metadata.name}')" != "" ]
                do
                  echo "$(kubectl get pods -l $LABELS --field-selector spec.nodeName=$NODE_NAME -n $NAMESPACE)"
                  sleep 2
                done
        fi
    fi
  IFS=$'\n'
  done
  
echo "Safely evicted all $DEPTYPE"
}


############### MAIN ###############

kubectl cordon $NODE_NAME
rollout Deployment
rollout StatefulSet

read -p "Do you want drain node $NODE_NAME?(y/n)" confirm 
if [ "$confirm" == "y" ]; then
    echo "$(kubectl drain $NODE_NAME --ignore-daemonsets $2 $3 $4)"
fi
