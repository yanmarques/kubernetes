/*
Copyright 2016 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"k8s.io/kubernetes/cmd/kubeadm/app"
	kubeadmv1beta3 "k8s.io/kubernetes/cmd/kubeadm/app/apis/kubeadm/v1beta3"
	kubeadmv1beta4 "k8s.io/kubernetes/cmd/kubeadm/app/apis/kubeadm/v1beta4"
	kubeadmutil "k8s.io/kubernetes/cmd/kubeadm/app/util"
	"k8s.io/kubernetes/pkg/config"
)

func main() {
	path, ok := os.LookupEnv("KUBELET_USERSPACE_ROOT_DIR")
	if !ok {
		fmt.Println("[ERROR] Missing environment variable 'KUBELET_USERSPACE_ROOT_DIR'")
		os.Exit(2)
	}
	normalizedPath, err := filepath.Abs(path)
	if err != nil {
		fmt.Printf("[ERROR] There is something wrong with provided 'KUBELET_USERSPACE_ROOT_DIR', given=%s error=%s\n", path, err)
		os.Exit(2)
	}
	config.UserspaceRootDir = normalizedPath

	kubeadmv1beta3.DefaultCertificatesDir = config.UserspaceRootDir + "/pki"
	kubeadmv1beta4.DefaultCertificatesDir = config.UserspaceRootDir + "/pki"

	kubeadmutil.CheckErr(app.Run())
}
