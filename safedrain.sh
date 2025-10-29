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
 
## List all pods on the specified node
echo "Listing all pods on node $NODE_NAME:"
kubectl get pods -A --field-selector spec.nodeName=$NODE_NAME -o wide
echo ""
 
## Confirm with the user if they want to evict all pods
read -p "Do you want to evict all pods listed above on node $NODE_NAME? (y/n) " confirm_pods
if [ "$confirm_pods" != "y" ]; then
    echo "Aborting operation as user did not confirm pod eviction."
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
          echo "$PODLIST was found with replicas on other nodes. Multi node replicas can be ignored for a re-rollout"
       else
                echo "A single pod belonging to deployment $DEPLOY_NAME. Deploying this pod to a new node"
                echo $(kubectl rollout restart -n $NAMESPACE $DEPTYPE $DEPLOY_NAME)
 
                ## Keep looping until the pod a been terminated from the node
               echo "Deleting the pod on the current node and waiting for it to start on a new node(this could take a while)...if it never terminates then you should look why the pod can't be deleted"
	       count=60
               while [ "$(kubectl get pods --no-headers -n $NAMESPACE -l $LABELS --field-selector spec.nodeName=$NODE_NAME -o=jsonpath='{range .items[*]}{.metadata.name}')" != "" ]
                do
                  echo -ne "Evicting $PODLIST: ${count}s \r"
                  ((count--))
                  #echo "$(kubectl get pods -l $LABELS --field-selector spec.nodeName=$NODE_NAME -n $NAMESPACE)"
                  sleep 1
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
echo "------- Draining node  ----------";
echo "$(kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data $2 $3 $4)"
echo "Drain completed and $NODE_NAME cordoned. Dont forget to uncordon the node when its ready to accept new pods"
