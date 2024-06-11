#!/bin/bash 

# Run the script without any argument. It might take 10 to 15 minutes to collect data.
# Please below Ref below document if controller can not be access via controller pod IP to enable REST API .
# Ref here for more info about REST API access https://open-docs.neuvector.com/automation/automation
# Please gzip the files under logs/date/ctr and send to support
# Change admin password


_DATE_=`date +%Y%m%d_%H%M%S`
if [ ! -d json ]; then
  mkdir json
fi
if [ ! -d logs/$_DATE_/ctr ]; then
  mkdir -p logs/$_DATE_/ctr
fi
if [ ! -d logs/$_DATE_/enf ]; then
  mkdir -p logs/$_DATE_/enf
fi

pass=admin
port=10443
_controllerIP_=`kubectl get pod -nneuvector -l app=neuvector-controller-pod -o jsonpath='{.items[0].status.podIP}'`
_PING_STATUS=`ping $_controllerIP_ -c 1 -w 2 | grep loss | awk '{print $6}' | awk -F% '{print $1}'`
#_controllerIP_=`svc.sh | grep controller-debug | awk '{print $5}'`
_hostIP_=`kubectl get pod -nneuvector -l app=neuvector-controller-pod  -o jsonpath='{.items[0].status.hostIP}'`
_RESTAPINPSVC_=`kubectl get svc -nneuvector | grep 10443 |grep -v fed|grep NodePort | awk '{print $1}'`
_RESTAPIPORT_=`kubectl get svc -nneuvector $_RESTAPINPSVC_ -o jsonpath='{.spec.ports[].nodePort}'`
_RESTAPILBSVC_=`kubectl get svc -nneuvector | grep 10443 |grep -v fed|grep LoadBalancer | awk '{print $1}'`
_RESTAPILBIP1_=`kubectl get svc -n neuvector $_RESTAPILBSVC_ -ojsonpath='{.spec.externalIPs[0]}'`
_RESTAPILBIP2_=`kubectl get svc -n neuvector $_RESTAPILBSVC_ -ojsonpath='{.status.loadBalancer.ingress[].ip}'`

if [  -z _RESTAPILBIP1_ ];then
  _RESTAPILBIP=$_RESTAPILBIP1_
else
  _RESTAPILBIP_=$_RESTAPILBIP2_
fi

if [ -z $_RESTAPILBIP_ ];then

  _RESTAPILBIP_=`kubectl get svc -n neuvector $_RESTAPILBSVC_ -ojsonpath='{.status.loadBalancer.ingress[].hostname}'`

fi

if [ ! -z $_RESTAPINPSVC_ ]; then 
   _controllerIP_=$_hostIP_
   port=$_RESTAPIPORT_
   echo "controller is accessed by REST API nodeport service"
   echo $_controllerIP_ $port
elif [ ! -z $_RESTAPILBSVC_ ]; then
   _controllerIP_=$_RESTAPILBIP_
   port=10443
   echo "controller is accessed by REST API LoadBalancer service"
   echo $_controllerIP_ $port
elif [ $_PING_STATUS = "0" ];then
   port=10443
   _controllerIP_=`kubectl get pod -nneuvector -l app=neuvector-controller-pod -o jsonpath='{.items[0].status.podIP}'`
   echo "controller is accessed by controller pod IP"
   echo $_controllerIP_ $port
else
   echo "controller can not be accessed "
   _APISTATUS_=0
   echo "controller profile can not be collected"
   #exit
fi



curl -k -H "Content-Type: application/json" -d '{"password": {"username": "admin", "password": '\"$pass\"'}}' "https://$_controllerIP_:$port/v1/auth" > /dev/null 2>&1 > json/token.json
_TOKEN_=`cat json/token.json | jq -r '.token.token'`
curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/controller" > /dev/null 2>&1  > json/controllers.json

ids=(`cat json/controllers.json | jq -r .controllers[].id`)

pods=(`kubectl get pod -nneuvector -o wide| grep neuvector-controller-pod |awk '{print $1}'`)
for pod in ${pods[@]}
do
	kubectl exec -ti -n neuvector $pod -- sh -c 'rm /var/neuvector/profile/*.prof' &> /dev/null
done
echo "capturing profile files"
for id in ${ids[@]} 
do
  curl -X POST -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" -d '{"profiling": {"duration": 30, "methods": ["memory", "cpu"]}}' "https://$_controllerIP_:$port/v1/controller/$id/profiling"   >/dev/null 2>&1 > json/ctrl-profile.json

done

sleep 33

pods=(`kubectl get pod -nneuvector -o wide| grep neuvector-controller-pod |awk '{print $1}'`)

for pod in ${pods[@]}
do

	kubectl cp -n neuvector $pod:var/nv_debug/profile/ctl.cpu.prof logs/$_DATE_/ctr/ctl.cpu.prof
	kubectl cp -n neuvector $pod:var/nv_debug/profile/ctl.goroutine.prof logs/$_DATE_/ctr/ctl.goroutine.prof
	#kubectl cp -n neuvector $pod:var/nv_debug/profile/ctl.gc.memory.prof logs/$_DATE_/ctr/ctl.gc.memory.prof
	kubectl cp -n neuvector $pod:var/nv_debug/profile/ctl.memory.prof logs/$_DATE_/ctr/ctl.memory.prof
	id=`echo $pod | cut -d "-" -f 5`
	mv logs/$_DATE_/ctr/ctl.cpu.prof logs/$_DATE_/ctr/ctl.${id}.cpu.prof
	mv logs/$_DATE_/ctr/ctl.goroutine.prof logs/$_DATE_/ctr/ctl.goroutine.${id}.prof
	#mv logs/$_DATE_/ctr/ctl.gc.memory.prof logs/$_DATE_/ctr/ctl.gc.memory.${id}.prof
	mv logs/$_DATE_/ctr/ctl.memory.prof logs/$_DATE_/ctr/ctl.${id}.memory.prof
done

echo "capturing ps aux output"
for pod in ${pods[@]}
do
        id=`echo $pod | cut -d "-" -f 5`
	kubectl exec -ti -nneuvector $pod -- sh -c "ps aux > ps-output-ctrl-${id}"
        kubectl cp -n neuvector $pod:ps-output-ctrl-${id}  logs/$_DATE_/ctr/ps-output-ctrl-${id}
done

kubectl top node > logs/$_DATE_/ctr/node-top-output
kubectl top pod -nneuvector  > logs/$_DATE_/ctr/neuvector-top-output



#REST API to enable cpath conn debug on all clusters in the cluster
curl -k -H "Content-Type: application/json" -d '{"password": {"username": "admin", "password": '\"$pass\"'}}' "https://$_controllerIP_:$port/v1/auth"   > /dev/null 2>&1 > json/token.json
_TOKEN_=`cat json/token.json | jq -r '.token.token'`

curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/controller"  > /dev/null 2>&1  > json/ctrls.json

_CTRLS_IDS_=(`cat json/ctrls.json | jq -r .controllers[].id`)

echo "Enabling controller debug log"

for id in  ${_CTRLS_IDS_[*]} ; do

   curl -X PATCH -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" -d '{"config": {"debug": ["cpath"]}}' "https://$_controllerIP_:$port/v1/controller/$id"  > /dev/null 2>&1   > json/set_debug.json
sleep 1
done
sleep 1

for id in  ${_CTRLS_IDS_[*]} ; do
   echo "Controller id and debug status : $id"
   curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/controller/$id/config"  > /dev/null 2>&1 > json/ctrl_config.json
   cat json/ctrl_config.json | jq .config.debug
done

sleep 10
echo "waiting 10seconds to collect debug log"
echo "Increase sleep seconds to collect log longer duration"

ctrl_pods=(`kubectl get pod -nneuvector -o wide| grep neuvector-controller-pod |awk '{print $1}'`)

for pod in ${ctrl_pods[@]}
do
        id=`echo $pod | cut -d "-" -f 5`
        kubectl logs -n neuvector $pod |  grep -v "TLS handshake error" > logs/$_DATE_/ctr/ctrl-${id}.log 
done

echo "Disabling controller debug log"

for id in  ${_CTRLS_IDS_[*]} ; do

   curl -X PATCH -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" -d '{"config": {"debug": [""]}}' "https://$_controllerIP_:$port/v1/controller/$id"  > /dev/null 2>&1   > json/set_debug.json
sleep 1
done
sleep 1

for id in  ${_CTRLS_IDS_[*]} ; do
   echo "Controller id and debug status : $id"
   curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/controller/$id/config"  > /dev/null 2>&1 > json/ctrl_config.json
   cat json/ctrl_config.json | jq .config.debug
done


### Find leader controller
curl -k -H "Content-Type: application/json" -d '{"password": {"username": "admin", "password": '\"$pass\"'}}' "https://$_controllerIP_:$port/v1/auth" > /dev/null 2>&1 > json/token.json
_TOKEN_=`cat json/token.json | jq -r '.token.token'`
curl -k -H "Content-Type: application/json" -H "X-Auth-Token: $_TOKEN_" "https://$_controllerIP_:$port/v1/controller" > /dev/null 2>&1  > json/controllers.json
leader_pod=`cat json/controllers.json | jq -r '."controllers"[] | select(.leader==true) | .display_name'`
echo $leader_pod

echo "saving kv snapshot"
kubectl exec -ti -nneuvector $leader_pod -- rm root/backup.snap &> /dev/null

kubectl exec -ti -nneuvector $leader_pod -- consul kv get -stale -recurse -separator="" -keys / > logs/$_DATE_/ctr/dump_keys

echo "coping kv snapshot local machine"
kubectl exec -ti -nneuvector $leader_pod -- consul snapshot save -stale backup.snap

kubectl exec -ti -nneuvector $leader_pod -- consul snapshot inspect -kvdetails -kvdepth 10 backup.snap > logs/$_DATE_/ctr/res.log

kubectl exec -ti -nneuvector $leader_pod -- ls -l

kubectl cp -n neuvector $leader_pod:backup.snap logs/$_DATE_/ctr/backup.snap

echo "saving YAML config for all controller and enforcer pods.."
kubectl get pods -n neuvector | grep controller | awk {'print $1'} | xargs kubectl get pod -n neuvector -o yaml > logs/$_DATE_/ctr/controller_pod_yaml_backup.log
kubectl get pods -n neuvector | grep enforcer | awk {'print $1'} | xargs kubectl get pod -n neuvector -o yaml > logs/$_DATE_/enf/enforcer_pod_yaml_backup.log
