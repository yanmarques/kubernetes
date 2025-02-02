#!/bin/sh
usage() {
      cat <<EOF >&2
Usage: $0 [-h] -l /path/to/local/directory

Run userspace kubelet.

Required arguments:
  -l PATH   Local directory to save all userspace kubelet configuration.

Options:
  -h        Show this message.
EOF
    exit 2
}

while getopts "l:d:h" o; do
  case "$o" in
    l)
      rootdir="$OPTARG"
      ;;
    *)
      usage
      ;;
  esac
done

if [ -z "$rootdir" ]; then
  usage
fi

set -exo pipefail
debug=false

if [ $1 = "--debug" ]; then
  debug=true
fi

if [ -n "$IP_ADDRESS" ]; then
  local_ip="$IP_ADDRESS"
else
  local_ip=$(ip -details -json address show | jq -r '.[] | select(.link_type == "ether").addr_info[] | select(.family == "inet").local')
  if [ -z "$local_ip" ]; then
	  echo "[ERROR] I tried to automatically discover the primary IP address of the system, but couldn't. Re-run with 'IP_ADDRESS' environment variable" >&2
	  exit 1
  fi
  echo "[INFO] using automatically discovered IP address: $local_ip"
fi

hostname="$(hostname)"

generate_user_pki() {
	local user=$1
	local key="$rootdir/pki/$user.key"
	local cert="$rootdir/pki/$user.crt"
	local csrconf="$rootdir/pki/$user-csr.conf"
	local csr="$rootdir/pki/$user.csr"
	local kubeconfig="$rootdir/$user.conf"

	cat <<EOF > "$csrconf"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $user
O = system:masters

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

	openssl genrsa -out "$key" 2048
	openssl req -new -key "$key" -out "$csr" -config "$csrconf"

	openssl x509 -req -in "$csr" -CA "$rootdir"/pki/ca.crt -CAkey "$rootdir"/pki/ca.key -CAcreateserial -out "$cert" -days 365 -extensions v3_req -extfile "$csrconf"

	cat <<EOF > "$kubeconfig"
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $(base64 -w 0 < "$rootdir/pki/ca.crt")
    server: https://$local_ip:6443
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:$user
  name: system:$user@kubernetes
current-context: system:$user@kubernetes
kind: Config
preferences: {}
users:
- name: system:$user
  user:
    client-certificate-data: $(base64 -w 0 < "$cert")
    client-key-data: $(base64 -w 0 < "$key")
EOF
}

mkdir -p "$rootdir"

mkdir -p "$rootdir/manifests"

cat <<EOF > "$rootdir/manifests/etcd.yaml"
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/etcd.advertise-client-urls: https://$local_ip:2379
  creationTimestamp: null
  labels:
    component: etcd
    tier: control-plane
  name: etcd
  namespace: kube-system
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://$local_ip:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --experimental-initial-corrupt-check=true
    - --experimental-watch-progress-notify-interval=5s
    - --initial-advertise-peer-urls=https://$local_ip:2380
    - --initial-cluster=$hostname=https://$local_ip:2380
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://$local_ip:2379
    - --listen-metrics-urls=http://127.0.0.1:2381
    - --listen-peer-urls=https://$local_ip:2380
    - --name=$hostname
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --snapshot-count=10000
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    image: registry.k8s.io/etcd:3.5.16-0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 2381
        scheme: HTTP
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: etcd
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 2381
        scheme: HTTP
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 2381
        scheme: HTTP
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: $rootdir/pki/etcd
      type: DirectoryOrCreate
    name: etcd-certs
  - hostPath:
      path: $rootdir/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
status: {}
EOF

cat <<EOF > "$rootdir/manifests/kube-apiserver.yaml"
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: $local_ip:6443
  creationTimestamp: null
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=$local_ip
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    image: registry.k8s.io/kube-apiserver:v1.32.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-apiserver
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki/ca-trust
      name: etc-pki-ca-trust
      readOnly: true
    - mountPath: /etc/pki/tls/certs
      name: etc-pki-tls-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: $rootdir/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: $rootdir/pki/ca-trust
      type: DirectoryOrCreate
    name: etc-pki-ca-trust
  - hostPath:
      path: $rootdir/pki/tls/certs
      type: DirectoryOrCreate
    name: etc-pki-tls-certs
  - hostPath:
      path: $rootdir/pki
      type: DirectoryOrCreate
    name: k8s-certs
status: {}
EOF

cat <<EOF > "$rootdir/manifests/kube-controller-manager.yaml"
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-controller-manager
    tier: control-plane
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --cluster-name=kubernetes
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --controllers=*,bootstrapsigner,tokencleaner
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --use-service-account-credentials=true
    image: registry.k8s.io/kube-controller-manager:v1.32.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-controller-manager
    resources:
      requests:
        cpu: 200m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/pki/ca-trust
      name: etc-pki-ca-trust
      readOnly: true
    - mountPath: /etc/pki/tls/certs
      name: etc-pki-tls-certs
      readOnly: true
    - mountPath: /etc/kubernetes/kubelet-plugins/volume/exec
      name: flexvolume-dir
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/controller-manager.conf
      name: kubeconfig
      readOnly: true
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: $rootdir/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: $rootdir/pki/ca-trust
      type: DirectoryOrCreate
    name: etc-pki-ca-trust
  - hostPath:
      path: $rootdir/pki/tls/certs
      type: DirectoryOrCreate
    name: etc-pki-tls-certs
  - hostPath:
      path: $rootdir/kubelet-plugins/volume/exec
      type: DirectoryOrCreate
    name: flexvolume-dir
  - hostPath:
      path: $rootdir/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: $rootdir/controller-manager.conf
      type: FileOrCreate
    name: kubeconfig
status: {}
EOF

cat <<EOF > "$rootdir/manifests/kube-scheduler.yaml"
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --kubeconfig=/etc/kubernetes/scheduler.conf
    - --leader-elect=true
    image: registry.k8s.io/kube-scheduler:v1.32.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-scheduler
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 10259
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 100m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/kubernetes/scheduler.conf
      name: kubeconfig
      readOnly: true
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: $rootdir/scheduler.conf
      type: FileOrCreate
    name: kubeconfig
status: {}
EOF

export KUBELET_USERSPACE_ROOT_DIR="$rootdir"

kubeadm init phase certs all --apiserver-advertise-address="$local_ip" --v=5
generate_user_pki kubernetes-admin
generate_user_pki kube-scheduler
generate_user_pki kube-controller-manager
generate_user_pki "system:node:$hostname"
cp "$rootdir/system:node:$hostname.conf" "$rootdir/kubelet.conf"
cp "$rootdir/kube-controller-manager.conf" "$rootdir/controller-manager.conf"
cp "$rootdir/kube-scheduler.conf" "$rootdir/scheduler.conf"

# ./kubernetes/cmd/kubelet/kubelet \
# 	--cgroups-per-qos=false \
# 	--enforce-node-allocatable=none \
# 	--register-node=false \
# 	--kubeconfig "$rootdir/kubelet.conf" \
# 	--pod-manifest-path "$rootdir/manifests" \
# 	--v=5 &
#
# pid=$!
#
# maxsecs=$(( 60 * 2 ))
# currsecs=0
#
# while true; do
# 	o="$(sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -o json | jq -r '.containers[] | select(.metadata.name == "kube-apiserver")')"
# 	echo "$o"
# 	if [ -n "$o" ] || [ $currsecs -gt $maxsecs ]; then
# 		if [ $currsecs -gt $maxsecs ]; then
# 			kill "$pid"
# 			echo "[ERROR] timed out waiting for kube-apiserver"
# 			exit 1
# 		fi
# 		kill "$pid"
# 		echo
# 		break
# 	fi
# 	currsecs=$(( currsecs + 1 ))
# 	sleep 1
# 	echo "[INFO] waiting api-server to be ready"
# done
#
is_android="$(uname -r | grep android)"
if [ -n "$is_android" ]; then
  getprop net.dns1 > "$rootdir"/resolv.conf
  getprop net.dns2 >> "$rootdir"/resolv.conf
else
  cp /etc/resolv.conf "$rootdir"/resolv.conf
fi

if $debug; then
  oldpath=$(pwd)
  cd ./kubernetes/cmd/kubelet
  exec dlv debug --log -- \
    --cgroups-per-qos=false \
    --enforce-node-allocatable=none \
    --register-node=true \
    --kubeconfig "$rootdir/kubelet.conf" \
    --pod-manifest-path "$rootdir/manifests" \
    --container-runtime-endpoint unix://$(pwd)/containerd.sock
else
  exec kubelet \
    --cgroups-per-qos=false \
    --enforce-node-allocatable=none \
    --register-node=true \
    --kubeconfig "$rootdir/kubelet.conf" \
    --pod-manifest-path "$rootdir/manifests" \
    --container-runtime-endpoint unix://$(pwd)/containerd.sock \
    --resolv-conf "$rootdir"/resolv.conf \
    --v=5
fi

