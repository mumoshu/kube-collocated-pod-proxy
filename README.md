# kube-collocated-pod-proxy

[DockerHub](https://hub.docker.com/r/mumoshu/kube-collocated-pod-proxy/)

`kube-collocated-pod-proxy` is a kubernetes sidecar container which runs a nginx udp(tcp coming!) load balancer for collocated pods(which is scheduled in the same node as the pod running this sidecar container) matching user specified pod selector.

It is useful when you'd like to connect pods in the same node e.g. connecting your applicaton pod to a Datadog's dd-agent daemonset pod in the same node without hard-coding of IPs or hostnames or tight-coupling with kubernetes. From your application, just connect `localhost:<port you specify>` and this sidecar container will proxy packets to another pods in the same node according to pod selector you've provided.

## Usage examples

### Connect localhost:8125 to dogstatsd running in the same node

You can also run this example via `kubectl create -f example.pod.yaml`

```
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  labels:
    app: web
spec:
  containers:
    - name: myapp
      image: gcr.io/google_containers/ubuntu-slim:0.4
      command:
      - sleep 9999
    - name: collocated-pod-proxy
      image: mumoshu/kube-collocated-pod-proxy:kube-1.3.6
      ports:
        - containerPort: 8125
      env:
      - name: PORT
        value: "8125"
      - name: SELECTOR
        value: "app=dd-agent"
      - name: PROTOCOL
        value: udp
      - name: NAMESPACE
        value: kube-system
      - name: MY_POD_NAME
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: MY_POD_NAMESPACE
        valueFrom:
          fieldRef:
            fieldPath: metadata.namespace
```

## Demo

In this demo, I'm going to run the pod proxy and test commands in the same container in the same pod. Although `collocated-pod-proxy` is intended to run as a sidecar container, you can see basic usage of it this way.

Now, run the collocated-pod-proxy in your kubernetes cluster:

```
$ PORT=8125 SELECTOR="app=dd-agent" PROTOCOL=udp make clean build kubectl-run
*snip*
kubectl run collocated-pod-proxy-test --rm --tty -i --restart=Never \
       	  --env PORT="8125" \
       	    --env SELECTOR="app=dd-agent" \
       	      --env PROTOCOL="udp" \
       	        --env NAMESPACE="kube-system" \
       		  --image mumoshu/kube-collocated-pod-proxy:0.9.0-kube-1.3.6 --command --
```

When it's ready, attach to it to see what's going to under the hood:

```
Waiting for pod default/collocated-pod-proxy-test to be running, status is Pending, pod ready: false

Hit enter for command prompt
                            \

export
+ export
*snip*
export NAMESPACE='kube-system'
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PORT='8125'
export PROTOCOL='udp'
export PWD='/home/nginx'
export SELECTOR='app=dd-agent'
export TERM='xterm'

selector="${SELECTOR}"
+ selector=app=dd-agent
namespace="${NAMESPACE}"
+ namespace=kube-system
node_name=$(kubectl get node --output=json | jq -r '.items[0].metadata.name')
+ jq -r .items[0].metadata.name
+ kubectl get node --output=json
+ node_name=minikubevm
pod_ip=$(kubectl get po --selector ${selector} --namespace ${namespace} --output json | jq -r ".items[] | select(.spec.nodeName == \"${node_name}\") | .status.podIP")
+ jq -r .items[] | select(.spec.nodeName == "minikubevm") | .status.podIP
+ kubectl get po --selector app=dd-agent --namespace kube-system --output json
+ pod_ip=172.17.0.2

pod_count=$(echo "${pod_ip}" | wc -l)
+ wc -l
+ echo 172.17.0.2
+ pod_count=1

if [ ${pod_count} -ne 1 ]; then
  echo Failed to determine which pod to connect. There are ${pod_count} candidates: ${pod_ip} 1>&2
  exit 1
fi
+ [ 1 -ne 1 ]

SOURCE_PORT=${SOURCE_PORT:-$PORT}
+ SOURCE_PORT=8125
TARGET_PORT=${TARGET_PORT:-$PORT}
+ TARGET_PORT=8125
TARGET_IP=${pod_ip}
+ TARGET_IP=172.17.0.2
```

basically, it

* asks kubernetes which node it runs on,
* searches for pods matching the pod-selector in the same node as the collocated-pod-proxy,
* asks kubernetes podIPs

then kube-collocated-pod-proxy dynamically generates nginx.conf via simple templating:

```
sed -e "s/%%TARGET_PORT%%/${TARGET_PORT}/" \
    -e "s/%%TARGET_IP%%/${TARGET_IP}/" \
    -e "s/%%PROTOCOL%%/${PROTOCOL}/" \
    -e "s/%%SOURCE_PORT%%/${SOURCE_PORT}/" nginx.conf.template > nginx.conf
+ sed -e s/%%TARGET_PORT%%/8125/ -e s/%%TARGET_IP%%/172.17.0.2/ -e s/%%PROTOCOL%%/udp/ -e s/%%SOURCE_PORT%%/8125/ nginx.conf.template
```

and finally it runs nginx managed with dumb-init as its pid 0:

```
exec dumb-init --single-child -- nginx -c $(pwd)/nginx.conf
+ pwd
+ exec dumb-init --single-child -- nginx -c /home/nginx/nginx.conf
```

nginx starts to write notice messages to stdout:

```
2016/10/05 07:27:10 [notice] 23#23: using the "epoll" event method
2016/10/05 07:27:10 [notice] 23#23: nginx/1.10.0 (Ubuntu)
2016/10/05 07:27:10 [notice] 23#23: OS: Linux 4.4.15-boot2docker
2016/10/05 07:27:10 [notice] 23#23: getrlimit(RLIMIT_NOFILE): 1048576:1048576
2016/10/05 07:27:10 [notice] 23#23: start worker processes
2016/10/05 07:27:10 [notice] 23#23: start worker process 24
```

Now, in another shell, lets run something to test connection via the nginx proxy.
The following sends Datadog-powered statsd metrics to a `dd-agent` pod created by the `dd-agent` daemonset via nginx proxy. This way, you don't need to hard-code ip or host of the dd-agent service/pod to send metrics to. Just send it to localhost:8125 and metrics are transparently proxied to `dd-agent` pod in the same node.

```
$ kubectl exec -it collocated-pod-proxy-test sh

# apt-get update && apt-get install ruby -y && gem install dogstatsd-ruby && irb -r datadog/statsd

irb(main):001:0> statsd = Datadog::Statsd.new
=> #<Datadog::Statsd:0x00000000ce04a0 @host="127.0.0.1", @port=8125, @prefix=nil, @socket=#<UDPSocket:fd 9>, @namespace=nil, @tags=[], @buffer=[], @max_buffer_size=50>

irb(main):002:0> statsd.increment("test.counter")
=> 16
```

Confirm that nginx receives udp packets and forwards to another pod(172.17.0.2) in the same node(minikubevm):

```
2016/10/05 07:30:56 [info] 24#24: *1 udp client 127.0.0.1:53831 connected to 0.0.0.0:8125
2016/10/05 07:30:56 [info] 24#24: *1 udp proxy 172.17.0.7:44385 connected to 172.17.0.2:8125
2016/10/05 07:30:57 [info] 24#24: *3 udp client 127.0.0.1:53831 connected to 0.0.0.0:8125
2016/10/05 07:30:57 [info] 24#24: *3 udp proxy 172.17.0.7:59510 connected to 172.17.0.2:8125
2016/10/05 07:31:00 [info] 24#24: *5 udp client 127.0.0.1:53831 connected to 0.0.0.0:8125
2016/10/05 07:31:00 [info] 24#24: *5 udp proxy 172.17.0.7:46184 connected to 172.17.0.2:8125
```
