# safedrain for Kubernetes
This is an wrapper script for 'Kubectl drain' that safely evicts the pods to prevent outages

## Problem: 
Annoyingly the 'kubectl drain' command first terminates pods on the nodes before they are started up on alternative node. This is especially a problem where you have single pod applications and you want to do node maintenance with interuptions to the pod.

## Solution:
This script checks what pods are running on your Node and calls 'kubectl rollout' to redeploy them in a safe manner. The new pods are created in a 'running' state before the old pods are terminated. After all the pods have been moved off the node it can be safely drained.


